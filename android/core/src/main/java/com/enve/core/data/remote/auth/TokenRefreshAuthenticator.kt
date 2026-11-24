// AGENT-LOCKED
package com.enve.core.data.remote.auth

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.remote.TokenRefreshContext
import com.enve.core.data.remote.TokenRefreshStrategy
import com.enve.core.data.model.BookSource
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.withLock
import okhttp3.Request
import okhttp3.Response
import okhttp3.Route
import okhttp3.Authenticator
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TokenRefreshAuthenticator @Inject constructor(
    private val vault: CredentialVault,
    private val connectionRegistry: ConnectionRegistry,
    private val tokenRefreshStrategies: Map<BookSource, @JvmSuppressWildcards TokenRefreshStrategy>,
    private val tokenRefreshCoordinator: TokenRefreshCoordinator,
) : Authenticator {

    override fun authenticate(route: Route?, response: Response): Request? {
        val path = response.request.url.encodedPath
        if (path.contains("auth/login") || path.contains("auth/refresh")) return null
        if (response.request.header("X-Retry-Auth") != null) return null

        val auth = response.request.tag(RequestAuthContext::class.java) ?: return null
        if (!response.request.url.belongsTo(auth.serverUrl, auth.credentialScope)) return null
        val activeConnectionId = auth.connectionId ?: return null
        val connection = connectionRegistry.getConnectionsSync()
            .find { it.id == activeConnectionId && it.enabled } ?: return null
        if (connection.serverUrl != auth.serverUrl) return null
        val source = connection.source
        val serverUrl = connection.serverUrl
        val strategy = tokenRefreshStrategies[source] ?: return null

        return runBlocking {
            tokenRefreshCoordinator.mutex.withLock {
                val currentToken = vault.get(CredentialVault.accessTokenKey(activeConnectionId))
                val requestToken = response.request.header("Authorization")
                    ?.removePrefix("Bearer ")?.trim()

                if (currentToken != null && currentToken != requestToken) {
                    return@withLock response.request.newBuilder()
                        .header("Authorization", "Bearer $currentToken")
                        .header("X-Retry-Auth", "1")
                        .build()
                }

                val newToken = strategy.refresh(
                    TokenRefreshContext(
                        source = source,
                        serverUrl = serverUrl,
                        connectionId = activeConnectionId,
                        connection = connection,
                        refreshToken = vault.get(CredentialVault.refreshTokenKey(activeConnectionId)),
                        username = vault.get(CredentialVault.usernameKey(activeConnectionId)),
                        password = vault.get(CredentialVault.passwordKey(activeConnectionId)),
                    ),
                )
                if (newToken != null) {
                    return@withLock response.request.newBuilder()
                        .header("Authorization", "Bearer $newToken")
                        .header("X-Retry-Auth", "1")
                        .build()
                }
                null
            }
        }
    }
}
