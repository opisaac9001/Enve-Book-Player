package com.enve.app.data.metadata

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.Book
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderMetadataUpdate
import com.enve.core.data.remote.ConnectionScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ProviderMetadataRepository @Inject constructor(
    private val adapters: Set<@JvmSuppressWildcards ProviderAdapter>,
    private val connectionRegistry: ConnectionRegistry,
    private val prefs: PreferencesManager,
) {
    private val connectionMutex = Mutex()

    suspend fun supportsProviderMetadataUpdate(book: Book): Boolean = withContext(Dispatchers.IO) {
        val adapter = adapters.firstOrNull { it.source == book.source }
            ?: return@withContext false
        adapter.supportsMetadataUpdate && connectionForBook(book) != null
    }

    suspend fun updateBookMetadata(
        book: Book,
        metadata: ProviderMetadataUpdate,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        val adapter = adapters.firstOrNull { it.source == book.source }
            ?: return@withContext Result.failure(IllegalStateException("${book.source.displayName} is not connected"))
        if (!adapter.supportsMetadataUpdate) {
            return@withContext Result.failure(UnsupportedOperationException("${book.source.displayName} metadata updates are not supported"))
        }

        val connection = connectionForBook(book)
            ?: return@withContext Result.failure(IllegalStateException("No enabled ${book.source.displayName} connection is available"))
        withConnectionContext(connection) { adapter.updateBookMetadata(book, metadata) }
    }

    private suspend fun connectionForBook(book: Book): ProviderConnection? {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        val connectionId = book.connectionId?.takeIf { it.isNotBlank() }
        if (connectionId != null) {
            return connections.find { it.id == connectionId }
        }
        return connections.filter { it.source == book.source }.singleOrNull()
    }

    private suspend fun withConnectionContext(
        connection: ProviderConnection,
        block: suspend () -> Result<Unit>,
    ): Result<Unit> {
        connectionMutex.withLock {
            prefs.setCachedConnectionContext(
                source = connection.source,
                serverUrl = connection.serverUrl,
                username = connection.username,
                connectionId = connection.id,
                accessToken = null,
                refreshToken = null,
                password = null,
            )
        }
        return withContext(ConnectionScope.asContextElement(connection.id)) {
            block()
        }
    }
}
