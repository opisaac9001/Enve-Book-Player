package com.enve.bookorbit

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BookOrbitEndpoints @Inject constructor(
    private val prefs: PreferencesManager,
    private val connectionRegistry: ConnectionRegistry,
) {
    fun currentConnection(): ProviderConnection? {
        val connections = connectionRegistry.getConnectionsSync()
        ConnectionScope.getConnectionId()?.let { scopedId ->
            connections.firstOrNull { it.id == scopedId }?.let { return it }
        }
        prefs.getActiveConnectionIdSync()?.let { activeId ->
            connections.firstOrNull { it.id == activeId }?.let { return it }
        }
        return connections.firstOrNull { it.source == BookSource.BOOKORBIT }
    }

    fun apiBaseUrl(): String = "${serverUrl().trimEnd('/')}/api/v1"

    fun coverUrl(bookId: Int): String = "${apiBaseUrl()}/books/$bookId/cover"

    private fun serverUrl(): String {
        currentConnection()?.serverUrl?.let { return it }
        return prefs.getServerUrlSync()?.takeIf { it.isNotBlank() } ?: error("No BookOrbit server URL configured")
    }
}
