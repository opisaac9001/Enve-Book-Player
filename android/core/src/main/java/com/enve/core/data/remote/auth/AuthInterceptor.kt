// AGENT-LOCKED
package com.enve.core.data.remote.auth

import com.enve.core.auth.CredentialVault
import com.enve.core.data.remote.AuthHeaderStrategy
import com.enve.core.data.remote.BearerAuthHeaderStrategy
import com.enve.core.data.remote.AuthHeaderContext
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.remote.TokenRefreshContext
import com.enve.core.data.remote.TokenRefreshStrategy
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response
import org.json.JSONObject
import java.util.Base64
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AuthInterceptor @Inject constructor(
    private val preferencesManager: PreferencesManager,
    private val connectionRegistry: com.enve.core.data.local.ConnectionRegistry,
    private val vault: CredentialVault,
    private val authHeaderStrategies: Map<BookSource, @JvmSuppressWildcards AuthHeaderStrategy>,
    private val bearerAuthHeaderStrategy: BearerAuthHeaderStrategy,
    private val tokenRefreshStrategies: Map<BookSource, @JvmSuppressWildcards TokenRefreshStrategy>,
) : Interceptor {

    private val proactiveMutex = Mutex()

    // Cache the decoded JWT exp claim so we don't Base64-decode + JSON-parse on every
    // single request. Tokens are immutable strings; once decoded, the answer is stable
    // for the lifetime of that token. Bounded so a long-running session that cycles
    // through many refreshed tokens doesn't accumulate forever - 32 is plenty.
    private val jwtExpCache: MutableMap<String, Long> = java.util.Collections.synchronizedMap(
        object : LinkedHashMap<String, Long>(32, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?): Boolean = size > 32
        }
    )

    override fun intercept(chain: Interceptor.Chain): Response {
        val original = chain.request()
        val path = original.url.encodedPath

        val originalHost = original.url.host
        val originalPort = original.url.port
        val scopedConnectionId = ConnectionScope.getConnectionId()
        val activeConnectionId = scopedConnectionId ?: preferencesManager.getActiveConnectionIdSync()
        val connections = connectionRegistry.getConnectionsSync()

        fun matchesHostPort(connServerUrl: String): Boolean {
            val url = connServerUrl.toHttpUrlOrNull() ?: return false
            return url.host.equals(originalHost, ignoreCase = true) && url.port == originalPort
        }

        // Public/auth endpoints skip the bearer/basic injection but STILL need the CF
        // Access cookie + per-connection custom headers - otherwise Cloudflare redirects
        // the login POST to the IdP and the server returns HTML instead of JSON.
        val stagedLoginHeaders = preferencesManager.getPendingLoginHeadersSync()
        val hasStagedLoginContext = stagedLoginHeaders.isNotEmpty()
        if (
            path.endsWith("/auth/login") ||
            path.endsWith("/auth/refresh") ||
            path.endsWith("/public-settings") ||
            path.endsWith("/api/v1/auth/login") ||
            path.endsWith("/api/v1/auth/refresh") ||
            path.endsWith("/login") ||
            path.endsWith("/api/v2/token") ||
            path.endsWith("/api/v2/token/app") ||
            path.contains("AuthenticateByName") ||
            path.contains("Account/login")
        ) {
            val cookie = preferencesManager.getPendingLoginCookieSync()?.takeIf { it.isNotBlank() }
            val scopedRegistered = scopedConnectionId
                ?.let { id -> connections.find { it.id == id } }
                ?.takeIf { matchesHostPort(it.serverUrl) }
            val matched = scopedRegistered ?: connections.find { matchesHostPort(it.serverUrl) }
            val matchedHeaders = matched?.let { conn ->
                buildMap {
                    putAll(conn.customHeaders)
                    if (conn.serviceClientId.isNotBlank()) put("CF-Access-Client-Id", conn.serviceClientId)
                    if (conn.serviceClientSecret.isNotBlank()) put("CF-Access-Client-Secret", conn.serviceClientSecret)
                }
            } ?: emptyMap()
            val authHeaders = if (hasStagedLoginContext) stagedLoginHeaders else matchedHeaders
            val withHeaders = original.newBuilder().apply {
                if (!cookie.isNullOrBlank()) header("Cookie", cookie)
                authHeaders.forEach { (k, v) ->
                    header(k, v)
                }
            }.build()
            return chain.proceed(withHeaders)
        }

        // When ConnectionScope is set, the caller has *explicitly* declared which
        // connection this request belongs to (e.g. fan-out in LibraryListResolver,
        // per-connection paged fetches). Prefer it over the "active" connection -
        // otherwise, when two accounts share the same host:port (two Grimmory users
        // on the same server), every fan-out call would route to the active token,
        // returning the active user's data for every connection's call. That bug
        // showed up as books appearing twice and the other account's libraries
        // missing from the picker.
        val scopedRegistered = scopedConnectionId
            ?.let { id -> connections.find { it.id == id } }
            ?.takeIf { matchesHostPort(it.serverUrl) }

        val activeConnection = activeConnectionId?.let { id -> connections.find { it.id == id } }
        val activeRegistered = activeConnection?.takeIf { matchesHostPort(it.serverUrl) }
        val activePending = if (activeConnection == null && activeConnectionId != null) {
            preferencesManager.getServerUrlSync()
                ?.takeIf { matchesHostPort(it) }
                ?.let { activeConnectionId }
        } else null

        val matchingConnection = scopedRegistered
            ?: activeRegistered
            ?: if (activePending != null) null
               else connections.find { conn -> matchesHostPort(conn.serverUrl) }

        val source = matchingConnection?.source ?: preferencesManager.getActiveBookSourceSync()
        val connectionId = matchingConnection?.id
            ?: activePending
            ?: scopedConnectionId
            ?: preferencesManager.getActiveConnectionIdSync()

        var token = connectionId?.let { vault.get(CredentialVault.accessTokenKey(it)) }
            ?: preferencesManager.getAccessTokenSync()

        val username = connectionId?.let { vault.get(CredentialVault.usernameKey(it)) }
            ?: preferencesManager.getUsernameSync()
            ?: ""
        val authHeaderStrategy = authHeaderStrategies[source] ?: bearerAuthHeaderStrategy

        val stagedHeaders = if (matchingConnection == null || hasStagedLoginContext) {
            stagedLoginHeaders
        } else {
            emptyMap()
        }
        val pendingLoginCookie = if (stagedHeaders.isNotEmpty() || matchingConnection == null) {
            preferencesManager.getPendingLoginCookieSync()?.takeIf { it.isNotBlank() }
        } else null

        val tokenRefreshStrategy = tokenRefreshStrategies[source]
        if (tokenRefreshStrategy != null && token != null && isJwtExpiringSoon(token, bufferSeconds = 60)) {
            val refreshed = runBlocking {
                proactiveMutex.withLock {
                    val latest = connectionId?.let { vault.get(CredentialVault.accessTokenKey(it)) } ?: preferencesManager.getAccessTokenSync()
                    if (latest != null && !isJwtExpiringSoon(latest, bufferSeconds = 60)) {
                        latest
                    } else {
                        val connection = matchingConnection
                            ?: connectionId?.let { id -> connections.find { it.id == id } }
                        tokenRefreshStrategy.refresh(
                            TokenRefreshContext(
                                source = source,
                                serverUrl = connection?.serverUrl ?: preferencesManager.getServerUrlSync().orEmpty(),
                                connectionId = connectionId,
                                connection = connection,
                                refreshToken = connectionId?.let { vault.get(CredentialVault.refreshTokenKey(it)) }
                                    ?: preferencesManager.getRefreshTokenSync(),
                                username = connectionId?.let { vault.get(CredentialVault.usernameKey(it)) }
                                    ?: preferencesManager.getUsernameSync(),
                                password = connectionId?.let { vault.get(CredentialVault.passwordKey(it)) }
                                    ?: vault.get(CredentialVault.KEY_PASSWORD),
                            ),
                        )
                    }
                }
            }
            if (refreshed != null) token = refreshed
        }

        val requestHeaders = stagedHeaders.ifEmpty {
            matchingConnection?.let { conn ->
                buildMap {
                    putAll(conn.customHeaders)
                    if (conn.serviceClientId.isNotBlank()) put("CF-Access-Client-Id", conn.serviceClientId)
                    if (conn.serviceClientSecret.isNotBlank()) put("CF-Access-Client-Secret", conn.serviceClientSecret)
                }
            } ?: emptyMap()
        }

        if (authHeaderStrategy.requiresToken && (token.isNullOrEmpty() || token == "ChangeMe!")) {
            if (pendingLoginCookie == null && requestHeaders.isEmpty()) return chain.proceed(original)
            val stagedRequest = original.newBuilder().apply {
                if (pendingLoginCookie != null) header("Cookie", pendingLoginCookie)
                requestHeaders.forEach { (k, v) -> header(k, v) }
            }.build()
            return chain.proceed(stagedRequest)
        }

        val builder = original.newBuilder()
            .header("User-Agent", "Enve/1.0 (Android; SDK ${android.os.Build.VERSION.SDK_INT})")

        requestHeaders.forEach { (key, value) ->
            builder.header(key, value)
        }

        if (source == BookSource.SILO && path.startsWith("/api/v1/") && connectionId != null) {
            vault.get(siloProfileIdKey(connectionId))?.takeIf { it.isNotBlank() }?.let { profileId ->
                builder.header("X-Profile-Id", profileId)
            }
        }

        if (pendingLoginCookie != null) {
            builder.header("Cookie", pendingLoginCookie)
        }

        val request = authHeaderStrategy.apply(
            AuthHeaderContext(
                original = original,
                builder = builder,
                token = token,
                username = username,
            ),
        )

        return chain.proceed(request)
    }

    private fun isJwtExpiringSoon(token: String, bufferSeconds: Long): Boolean {
        val exp = jwtExpCache[token] ?: run {
            val decoded = decodeJwtExp(token)
            // Sentinel 0 marks "couldn't decode" so we don't retry-decode on every request.
            jwtExpCache[token] = decoded
            decoded
        }
        if (exp <= 0L) return false
        return System.currentTimeMillis() / 1000L >= (exp - bufferSeconds)
    }

    private fun decodeJwtExp(token: String): Long = try {
        val parts = token.split(".")
        if (parts.size != 3) {
            0L
        } else {
            var base64 = parts[1].replace('-', '+').replace('_', '/')
            base64 += "=".repeat((4 - base64.length % 4) % 4)
            val payload = String(Base64.getDecoder().decode(base64), Charsets.UTF_8)
            JSONObject(payload).optLong("exp", 0L)
        }
    } catch (_: Exception) {
        0L
    }

    private fun siloProfileIdKey(connectionId: String) = "silo_profile_id_$connectionId"

}
