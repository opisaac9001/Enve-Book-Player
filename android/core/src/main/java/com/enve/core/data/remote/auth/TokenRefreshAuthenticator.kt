// AGENT-LOCKED
package com.enve.core.data.remote.auth

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.remote.TokenRefreshContext
import com.enve.core.data.remote.TokenRefreshStrategy
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.Request
import okhttp3.Response
import okhttp3.Route
import okhttp3.Authenticator
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TokenRefreshAuthenticator @Inject constructor(
    private val preferencesManager: PreferencesManager,
    private val vault: CredentialVault,
    private val connectionRegistry: ConnectionRegistry,
    private val tokenRefreshStrategies: Map<BookSource, @JvmSuppressWildcards TokenRefreshStrategy>,
) : Authenticator {

    private val refreshMutex = Mutex()

    override fun authenticate(route: Route?, response: Response): Request? {
        val path = response.request.url.encodedPath
        // Never retry auth / login endpoints to prevent loops
        if (path.contains("auth/login") || path.contains("auth/refresh")) return null
        if (response.request.header("X-Retry-Auth") != null) return null

        val scopedId = ConnectionScope.getConnectionId()
        val connections = connectionRegistry.getConnectionsSync()
        val activeConnectionId = scopedId ?: preferencesManager.getActiveConnectionIdSync()
        val connection = activeConnectionId?.let { id -> connections.find { it.id == id } }
        val source = connection?.source ?: preferencesManager.getActiveBookSourceSync()
        val serverUrl = if (connection != null) {
            connection.serverUrl
        } else {
            preferencesManager.getServerUrlSync()
        }
        val strategy = tokenRefreshStrategies[source] ?: return null
        if (serverUrl.isNullOrBlank()) return null

        return runBlocking {
            refreshMutex.withLock {
                val currentToken = activeConnectionId?.let { vault.get(CredentialVault.accessTokenKey(it)) }
                    ?: preferencesManager.getAccessTokenSync()
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
                        refreshToken = activeConnectionId?.let { vault.get(CredentialVault.refreshTokenKey(it)) }
                            ?: preferencesManager.getRefreshTokenSync(),
                        username = activeConnectionId?.let { vault.get(CredentialVault.usernameKey(it)) }
                            ?: preferencesManager.getUsernameSync(),
                        password = activeConnectionId?.let { vault.get(CredentialVault.passwordKey(it)) }
                            ?: vault.get(CredentialVault.KEY_PASSWORD),
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
