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
import kotlinx.coroutines.sync.withLock
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
    private val tokenRefreshCoordinator: TokenRefreshCoordinator,
) : Interceptor {

    private val jwtExpCache: MutableMap<String, Long> = java.util.Collections.synchronizedMap(
        object : LinkedHashMap<String, Long>(32, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?): Boolean = size > 32
        }
    )

    override fun intercept(chain: Interceptor.Chain): Response {
        val original = chain.request()
        val path = original.url.encodedPath

        val scopedConnectionId = ConnectionScope.getConnectionId()
        val attempt = com.enve.core.data.remote.LoginAttemptScope.get()
        val connections = connectionRegistry.getConnectionsSync().filter {
            it.enabled || (it.id == scopedConnectionId && attempt != null && it.source == attempt.source &&
                it.serverUrl.trimEnd('/') == attempt.serverUrl.trimEnd('/'))
        }
        if (scopedConnectionId == null && attempt != null &&
            !original.url.belongsTo(attempt.serverUrl, headerStrategy(attempt.source).credentialScope)
        ) {
            return chain.proceed(original)
        }
        val login = attempt?.takeIf { scopedConnectionId == null }
        val matchingConnection = if (login != null) null else if (scopedConnectionId != null) {
            connections.find {
                it.id == scopedConnectionId && original.url.belongsTo(it.serverUrl, headerStrategy(it.source).credentialScope)
            }
        } else {
            val matching = connections.filter { original.url.belongsTo(it.serverUrl, headerStrategy(it.source).credentialScope) }
            matching.find { it.id == preferencesManager.getActiveConnectionIdSync() }
                ?: matching.singleOrNull()
        }
        if (matchingConnection == null && login == null) return chain.proceed(original)

        val connectionId = matchingConnection?.id
        val source = matchingConnection?.source ?: requireNotNull(login).source
        val serverUrl = matchingConnection?.serverUrl ?: requireNotNull(login).serverUrl
        val authHeaderStrategy = headerStrategy(source)
        val requestHeaders = attempt?.takeIf {
            it.source == source && original.url.belongsTo(it.serverUrl, authHeaderStrategy.credentialScope)
        }?.headers ?: buildMap {
            val connection = requireNotNull(matchingConnection)
            putAll(connection.customHeaders)
            if (connection.serviceClientId.isNotBlank()) put("CF-Access-Client-Id", connection.serviceClientId)
            if (connection.serviceClientSecret.isNotBlank()) put("CF-Access-Client-Secret", connection.serviceClientSecret)
        }
        val auth = RequestAuthContext(
            connectionId,
            serverUrl,
            requestHeaders.keys + setOf("Authorization", "Cookie", "X-Plex-Token", "X-Emby-Token", "X-Profile-Id", "X-Profile-Token"),
            authHeaderStrategy.credentialScope,
        )
        if (
            path.endsWith("/auth/login") || path.endsWith("/auth/refresh") ||
            path.endsWith("/public-settings") || path.endsWith("/login") ||
            path.endsWith("/api/v2/token") || path.endsWith("/api/v2/token/app") ||
            path.contains("AuthenticateByName") || path.contains("Account/login")
        ) {
            return chain.proceed(original.newBuilder().apply {
                tag(RequestAuthContext::class.java, auth)
                requestHeaders.forEach { (key, value) -> header(key, value) }
            }.build())
        }

        var token = if (connectionId != null) vault.get(CredentialVault.accessTokenKey(connectionId))
            else login?.accessToken
        val username = if (connectionId != null) vault.get(CredentialVault.usernameKey(connectionId)).orEmpty()
            else login?.username.orEmpty()

        val tokenRefreshStrategy = tokenRefreshStrategies[source]
        if (connectionId != null && tokenRefreshStrategy != null && token != null && isJwtExpiringSoon(token, bufferSeconds = 60)) {
            val refreshed = runBlocking {
                tokenRefreshCoordinator.mutex.withLock {
                    val latest = vault.get(CredentialVault.accessTokenKey(connectionId))
                    if (latest != null && !isJwtExpiringSoon(latest, bufferSeconds = 60)) {
                        latest
                    } else {
                        val connection = requireNotNull(matchingConnection)
                        tokenRefreshStrategy.refresh(
                            TokenRefreshContext(
                                source = source,
                                serverUrl = connection.serverUrl,
                                connectionId = connectionId,
                                connection = connection,
                                refreshToken = vault.get(CredentialVault.refreshTokenKey(connectionId)),
                                username = vault.get(CredentialVault.usernameKey(connectionId)),
                                password = vault.get(CredentialVault.passwordKey(connectionId)),
                            ),
                        )
                    }
                }
            }
            if (refreshed != null) token = refreshed
        }

        if (authHeaderStrategy.requiresToken && (token.isNullOrEmpty() || token == "ChangeMe!")) {
            val stagedRequest = original.newBuilder().apply {
                tag(RequestAuthContext::class.java, auth)
                requestHeaders.forEach { (k, v) -> header(k, v) }
            }.build()
            return chain.proceed(stagedRequest)
        }

        val builder = original.newBuilder()
            .tag(RequestAuthContext::class.java, auth)
            .header("User-Agent", "Enve/1.0 (Android; SDK ${android.os.Build.VERSION.SDK_INT})")

        requestHeaders.forEach { (key, value) ->
            builder.header(key, value)
        }

        if (source == BookSource.SILO && path.contains("/api/v2/") && connectionId != null) {
            vault.get(siloProfileIdKey(connectionId))?.takeIf { it.isNotBlank() }?.let { profileId ->
                builder.header("X-Profile-Id", profileId)
                vault.get("silo_profile_token_$connectionId")?.takeIf { it.isNotBlank() }?.let { proof ->
                    builder.header("X-Profile-Token", proof)
                }
            }
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

    private fun headerStrategy(source: BookSource): AuthHeaderStrategy =
        authHeaderStrategies[source] ?: bearerAuthHeaderStrategy

    private fun isJwtExpiringSoon(token: String, bufferSeconds: Long): Boolean {
        val exp = jwtExpCache[token] ?: run {
            val decoded = decodeJwtExp(token)
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
