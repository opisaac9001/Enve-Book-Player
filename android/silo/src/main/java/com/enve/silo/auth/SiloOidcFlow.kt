package com.enve.silo.auth

import android.net.Uri
import android.util.Base64
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.di.RefreshClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.MessageDigest
import java.security.SecureRandom
import javax.inject.Inject
import javax.inject.Provider
import javax.inject.Singleton

sealed interface SiloOidcStart {
    data class Ready(val authUrl: String, val serverUrl: String) : SiloOidcStart
    data class Failed(val message: String) : SiloOidcStart
}

sealed interface SiloOidcCallback {
    data class Success(val serverUrl: String, val username: String) : SiloOidcCallback
    data object NoPending : SiloOidcCallback
    data class Failed(val message: String) : SiloOidcCallback
}

@Singleton
class SiloOidcFlow @Inject constructor(
    @RefreshClient clientProvider: Provider<OkHttpClient>,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
) {
    private val client = clientProvider.get().newBuilder().followRedirects(false).build()
    private val json = Json { ignoreUnknownKeys = true }

    private data class Pending(
        val serverUrl: String,
        val origin: String,
        val serverId: String,
        val verifier: String,
        val state: String,
        val headers: Map<String, String>,
    )

    @Volatile private var pending: Pending? = null

    suspend fun start(serverUrl: String, headers: Map<String, String>): SiloOidcStart = withContext(Dispatchers.IO) {
        try {
            val base = serverUrl.toHttpUrlOrNull() ?: error("Enter a valid Silo server URL.")
            val capabilities = get<OAuthCapabilities>(serverUrl, "/api/v2/auth/oauth/capabilities", headers)
            if (!capabilities.native) error("Silo native SSO is unavailable. Configure the server public URL and an OIDC sign-in plugin.")
            val providers = get<AuthProviders>(serverUrl, "/api/v2/auth/providers", headers)
            val provider = providers.items.firstOrNull { it.mode == "oauth" && !it.nativeStartPath.isNullOrBlank() }
                ?: error("No Silo OIDC sign-in provider is available.")
            val path = requireNotNull(provider.nativeStartPath)
            if (!path.startsWith("/api/v2/auth/oauth/") || !path.endsWith("/native/start") ||
                path.contains('?') || path.contains('#') || path.contains("..")
            ) error("Silo returned an invalid sign-in path.")
            val identity = get<ServerIdentity>(serverUrl, "/api/v2/system/identity", headers)
            val verifier = randomValue(64)
            val state = randomValue(32)
            val authUrl = (serverUrl.trimEnd('/') + path).toHttpUrlOrNull()
                ?: error("Silo returned an invalid sign-in URL.")
            if (origin(authUrl) != origin(base)) error("Silo sign-in must start on the saved server.")
            pending = Pending(serverUrl, origin(base), identity.serverId, verifier, state, headers)
            SiloOidcStart.Ready(
                authUrl.newBuilder()
                    .addQueryParameter("code_challenge", challenge(verifier))
                    .addQueryParameter("code_challenge_method", "S256")
                    .addQueryParameter("app_state", state)
                    .build().toString(),
                serverUrl,
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            pending = null
            SiloOidcStart.Failed(e.message ?: "Could not start Silo SSO.")
        }
    }

    suspend fun completeCallback(uri: Uri): SiloOidcCallback = withContext(Dispatchers.IO) {
        val flow = pending ?: return@withContext SiloOidcCallback.NoPending
        if (uri.scheme != "org.siloserver.silo" || uri.host != null || uri.path != "/auth/callback") {
            return@withContext SiloOidcCallback.Failed("Invalid Silo sign-in callback.")
        }
        pending = null
        fun parameter(name: String): String? = uri.getQueryParameters(name).singleOrNull()
        val issuer = parameter("iss")?.toHttpUrlOrNull()
        if (parameter("state") != flow.state ||
            parameter("server") != flow.serverId ||
            issuer == null || issuer.encodedPath != "/" || issuer.query != null || issuer.fragment != null ||
            issuer.username.isNotEmpty() || issuer.password.isNotEmpty() || origin(issuer) != flow.origin
        ) return@withContext SiloOidcCallback.Failed("Silo sign-in returned from a different session or server.")
        if ("link" in uri.queryParameterNames) return@withContext SiloOidcCallback.Failed("Silo returned an account-link response.")
        val authError = parameter("error")
        if ("error" in uri.queryParameterNames && (authError.isNullOrBlank() || "code" in uri.queryParameterNames)) {
            return@withContext SiloOidcCallback.Failed("Invalid Silo sign-in callback.")
        }
        if (authError != null) return@withContext SiloOidcCallback.Failed("Silo sign-in failed: $authError")
        val code = parameter("code")?.takeIf { it.isNotBlank() }
            ?: return@withContext SiloOidcCallback.Failed("Silo sign-in returned no code.")
        try {
            val body = json.encodeToString(OAuthCompletion(code, flow.verifier))
            val request = Request.Builder()
                .url(flow.serverUrl.trimEnd('/') + "/api/v2/auth/oauth/complete")
                .post(body.toRequestBody("application/json".toMediaType()))
                .header("Accept", "application/json")
                .applyHeaders(flow.headers)
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) error("Silo sign-in failed: HTTP ${response.code}")
                val session = json.decodeFromString<OAuthSession>(response.body?.string().orEmpty())
                prefs.saveAuth(session.accessToken, session.refreshToken)
                SiloOidcCallback.Success(flow.serverUrl, session.user.username)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            SiloOidcCallback.Failed(e.message ?: "Could not complete Silo sign-in.")
        }
    }

    suspend fun persistTokensForConnection(connectionId: String, username: String) {
        prefs.accessToken.first()?.takeIf { it.isNotBlank() }?.let {
            vault.put(CredentialVault.accessTokenKey(connectionId), it)
        }
        prefs.refreshToken.first()?.takeIf { it.isNotBlank() }?.let {
            vault.put(CredentialVault.refreshTokenKey(connectionId), it)
        }
        vault.put(CredentialVault.usernameKey(connectionId), username)
    }

    private inline fun <reified T> get(serverUrl: String, path: String, headers: Map<String, String>): T {
        val request = Request.Builder()
            .url(serverUrl.trimEnd('/') + path)
            .header("Accept", "application/json")
            .applyHeaders(headers)
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("Silo sign-in discovery failed: HTTP ${response.code}")
            return json.decodeFromString(response.body?.string().orEmpty())
        }
    }

    private fun Request.Builder.applyHeaders(headers: Map<String, String>) = apply {
        headers.forEach { (key, value) -> header(key, value) }
    }

    private fun origin(url: HttpUrl): String {
        val host = if (':' in url.host) "[${url.host}]" else url.host
        val defaultPort = if (url.scheme == "https") 443 else 80
        return "${url.scheme}://$host" + if (url.port == defaultPort) "" else ":${url.port}"
    }

    private fun randomValue(byteCount: Int): String {
        val bytes = ByteArray(byteCount)
        random.nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    private fun challenge(verifier: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII))
        return Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    @Serializable private data class OAuthCapabilities(val native: Boolean = false)
    @Serializable private data class AuthProviders(val items: List<AuthProvider> = emptyList())
    @Serializable private data class AuthProvider(
        val mode: String,
        @SerialName("native_start_path") val nativeStartPath: String? = null,
    )
    @Serializable private data class ServerIdentity(@SerialName("server_id") val serverId: String)
    @Serializable private data class OAuthCompletion(
        val code: String,
        @SerialName("code_verifier") val codeVerifier: String,
    )
    @Serializable private data class OAuthSession(
        @SerialName("access_token") val accessToken: String,
        @SerialName("refresh_token") val refreshToken: String,
        val user: OAuthUser,
    )
    @Serializable private data class OAuthUser(val username: String)

    private companion object {
        val random = SecureRandom()
    }
}
