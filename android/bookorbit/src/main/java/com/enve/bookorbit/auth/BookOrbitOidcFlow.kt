// AGENT-LOCKED
package com.enve.bookorbit.auth

import android.net.Uri
import android.util.Base64
import com.enve.bookorbit.dto.BookOrbitOidcCallbackRequest
import com.enve.bookorbit.dto.BookOrbitOidcProviderDto
import com.enve.bookorbit.dto.BookOrbitOidcStateDto
import com.enve.bookorbit.dto.BookOrbitOidcTokenDto
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.di.RefreshClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
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

sealed class BookOrbitOidcStart {
    data class Ready(val authUrl: String, val serverUrl: String) : BookOrbitOidcStart()
    data class Failed(val message: String) : BookOrbitOidcStart()
}

sealed class BookOrbitOidcCallback {
    data class Success(val serverUrl: String, val username: String) : BookOrbitOidcCallback()
    data object NoPending : BookOrbitOidcCallback()
    data class Failed(val message: String) : BookOrbitOidcCallback()
}

@Singleton
class BookOrbitOidcFlow @Inject constructor(
    @RefreshClient private val clientProvider: Provider<OkHttpClient>,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
) {
    private data class Pending(
        val serverUrl: String,
        val verifier: String,
        val state: String,
        val nonce: String,
        val redirectUri: String,
        val headers: Map<String, String>,
    )

    @Volatile private var pending: Pending? = null

    private val client get() = clientProvider.get()
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }

    suspend fun start(normalizedServerUrl: String, headers: Map<String, String>): BookOrbitOidcStart = withContext(Dispatchers.IO) {
        runCatching {
            val provider = publicProvider(normalizedServerUrl, headers)
            val state = oidcState(normalizedServerUrl, provider.slug, headers)
            val verifier = generateVerifier()
            val nonce = generateState() + generateState()
            val redirectUri = redirectUri(normalizedServerUrl)
            val authUrl = authorizationUrl(
                endpoint = state.authorizationEndpoint,
                provider = provider,
                redirectUri = redirectUri,
                challenge = challenge(verifier),
                state = state.state,
                nonce = nonce,
            )
            pending = Pending(
                serverUrl = normalizedServerUrl,
                verifier = verifier,
                state = state.state,
                nonce = nonce,
                redirectUri = redirectUri,
                headers = headers,
            )
            BookOrbitOidcStart.Ready(authUrl = authUrl, serverUrl = normalizedServerUrl)
        }.getOrElse { e ->
            pending = null
            BookOrbitOidcStart.Failed(e.message ?: "Failed to start BookOrbit SSO login")
        }
    }

    suspend fun completeCallback(uri: Uri): BookOrbitOidcCallback = withContext(Dispatchers.IO) {
        val authError = uri.getQueryParameter("error")
        if (!authError.isNullOrBlank()) {
            pending = null
            return@withContext BookOrbitOidcCallback.Failed("BookOrbit SSO error: $authError")
        }

        val code = uri.getQueryParameter("code")
        val returnedState = uri.getQueryParameter("state")
        val p = pending ?: return@withContext BookOrbitOidcCallback.NoPending

        if (code.isNullOrBlank() || returnedState.isNullOrBlank()) {
            pending = null
            return@withContext BookOrbitOidcCallback.Failed("BookOrbit SSO response was missing code or state.")
        }
        if (returnedState != p.state) {
            pending = null
            return@withContext BookOrbitOidcCallback.Failed("BookOrbit SSO state mismatch (possible CSRF). Try again.")
        }

        runCatching {
            val token = exchangeCode(p, code)
            prefs.saveAuth(token.accessToken, token.refreshToken)
            pending = null
            BookOrbitOidcCallback.Success(serverUrl = p.serverUrl, username = token.username)
        }.getOrElse { e ->
            pending = null
            BookOrbitOidcCallback.Failed(e.message ?: "BookOrbit SSO token exchange failed")
        }
    }

    suspend fun persistTokensForConnection(connectionId: String, username: String) {
        val accessToken = prefs.accessToken.first()
        val refreshToken = prefs.refreshToken.first()
        if (!accessToken.isNullOrBlank()) {
            vault.put(CredentialVault.accessTokenKey(connectionId), accessToken)
        }
        if (!refreshToken.isNullOrBlank()) {
            vault.put(CredentialVault.refreshTokenKey(connectionId), refreshToken)
        }
        if (username.isNotBlank()) {
            vault.put(CredentialVault.usernameKey(connectionId), username)
        }
    }

    fun cancel() {
        pending = null
    }

    private fun publicProvider(serverUrl: String, headers: Map<String, String>): BookOrbitOidcProviderDto {
        val url = "$serverUrl/api/v1/app-settings/oidc/providers/public"
        val request = Request.Builder()
            .url(url)
            .header("Accept", "application/json")
            .applyHeaders(headers)
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("Failed to fetch BookOrbit SSO providers: HTTP ${response.code}")
            val providers = json.decodeFromString<List<BookOrbitOidcProviderDto>>(response.body?.string().orEmpty())
            return providers.firstOrNull { it.enabled } ?: providers.firstOrNull()
                ?: error("No enabled BookOrbit SSO providers were found.")
        }
    }

    private fun oidcState(serverUrl: String, slug: String, headers: Map<String, String>): BookOrbitOidcStateDto {
        val encodedSlug = Uri.encode(slug)
        val request = Request.Builder()
            .url("$serverUrl/api/v1/auth/oidc/$encodedSlug/state")
            .post("".toRequestBody(null))
            .header("Accept", "application/json")
            .applyHeaders(headers)
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("Failed to start BookOrbit SSO login: HTTP ${response.code}")
            return json.decodeFromString(response.body?.string().orEmpty())
        }
    }

    private fun authorizationUrl(
        endpoint: String,
        provider: BookOrbitOidcProviderDto,
        redirectUri: String,
        challenge: String,
        state: String,
        nonce: String,
    ): String {
        val base = endpoint.toHttpUrlOrNull() ?: error("BookOrbit SSO provider returned an invalid authorization endpoint.")
        return base.newBuilder()
            .addQueryParameter("response_type", "code")
            .addQueryParameter("client_id", provider.clientId)
            .addQueryParameter("redirect_uri", redirectUri)
            .addQueryParameter("scope", provider.scopes)
            .addQueryParameter("code_challenge", challenge)
            .addQueryParameter("code_challenge_method", "S256")
            .addQueryParameter("state", state)
            .addQueryParameter("nonce", nonce)
            .build()
            .toString()
    }

    private fun exchangeCode(pending: Pending, code: String): TokenResult {
        val body = json.encodeToString(
            BookOrbitOidcCallbackRequest(
                code = code,
                codeVerifier = pending.verifier,
                redirectUri = pending.redirectUri,
                nonce = pending.nonce,
                state = pending.state,
            )
        )
        val request = Request.Builder()
            .url("${pending.serverUrl}/api/v1/auth/oidc/callback")
            .post(body.toRequestBody("application/json".toMediaType()))
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .applyHeaders(pending.headers)
            .build()
        client.newCall(request).execute().use { response ->
            val rawBody = response.body?.string().orEmpty()
            if (!response.isSuccessful) error(rawBody.ifBlank { "BookOrbit SSO callback failed: HTTP ${response.code}" })
            val token = json.decodeFromString<BookOrbitOidcTokenDto>(rawBody)
            val refreshToken = BookOrbitAuthCookies.refreshToken(response.headers)
            return TokenResult(token.accessToken, refreshToken, token.user.username)
        }
    }

    private fun redirectUri(serverUrl: String): String =
        "${serverUrl.trimEnd('/')}/oauth2-callback"

    private fun Request.Builder.applyHeaders(headers: Map<String, String>): Request.Builder = apply {
        headers.forEach { (key, value) -> header(key, value) }
    }

    private fun generateVerifier(): String {
        val bytes = ByteArray(64)
        random.nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    private fun challenge(verifier: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII))
        return Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    private fun generateState(): String {
        val bytes = ByteArray(16)
        random.nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    private data class TokenResult(
        val accessToken: String,
        val refreshToken: String?,
        val username: String,
    )

    private companion object {
        val random = SecureRandom()
    }
}
