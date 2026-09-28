package com.enve.app.data.opds

import com.enve.app.data.repository.isSameOpdsOrigin
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.AuthHeaderContext
import com.enve.core.data.remote.AuthHeaderStrategy
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.remote.TokenRefreshContext
import com.enve.core.data.remote.TokenRefreshStrategy
import okhttp3.Credentials
import okhttp3.Request
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OpdsAuthHeaderStrategy @Inject constructor(
    private val authStore: OpdsAuthStore,
    private val connectionRegistry: ConnectionRegistry,
) : AuthHeaderStrategy {

    override val requiresToken: Boolean = false

    override fun apply(context: AuthHeaderContext): Request {
        if (context.original.header("Authorization") != null) return context.builder.build()
        val url = context.original.url.toString()
        val scoped = connectionRegistry.getScopedConnectionSync()
        val configured = if (scoped == null) connectionRegistry.getConnectionsSync() else emptyList()
        if (!opdsCredentialsAllowed(scoped, configured, url)) return context.builder.build()

        val session = ConnectionScope.getConnectionId()?.let(authStore::session)
        if (session != null && session.hasBearer) {
            return context.builder.header("Authorization", "Bearer ${session.accessToken}").build()
        }
        if (session != null && session.hasBasic) {
            return context.builder
                .header("Authorization", Credentials.basic(session.username.orEmpty(), session.password.orEmpty()))
                .build()
        }

        if (context.username.isBlank() && context.token.isNullOrBlank()) return context.builder.build()
        return context.builder
            .header("Authorization", Credentials.basic(context.username, context.token.orEmpty()))
            .build()
    }
}

internal fun opdsCredentialsAllowed(
    scoped: ProviderConnection?,
    configured: List<ProviderConnection>,
    url: String,
): Boolean {
    if (scoped != null) return isSameOpdsOrigin(scoped.serverUrl, url)
    return configured.any { it.source == BookSource.OPDS && isSameOpdsOrigin(it.serverUrl, url) }
}

@Singleton
class OpdsTokenRefreshStrategy @Inject constructor(
    private val authStore: OpdsAuthStore,
    private val oauth: OpdsOAuthClient,
) : TokenRefreshStrategy {

    override fun refresh(context: TokenRefreshContext): String? {
        val connectionId = context.connectionId ?: return null
        val session = authStore.session(connectionId) ?: return null

        val renewed = session.refreshUrl?.let { url ->
            session.refreshToken?.let { oauth.refreshBlocking(url, it) }
        } ?: session.tokenUrl?.let { url ->
            val username = session.username ?: context.username?.takeIf { it.isNotBlank() } ?: return@let null
            val password = session.password ?: context.password?.takeIf { it.isNotBlank() } ?: return@let null
            oauth.passwordBlocking(url, username, password)
        } ?: return null

        authStore.save(
            connectionId,
            session.copy(
                accessToken = renewed.accessToken,
                refreshToken = renewed.refreshToken ?: session.refreshToken,
                expiresAtMs = renewed.expiresAtMs,
            ),
        )
        return renewed.accessToken
    }
}
