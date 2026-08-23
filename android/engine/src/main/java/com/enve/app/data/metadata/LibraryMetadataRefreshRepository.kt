package com.enve.app.data.metadata

import com.enve.app.data.repository.LibraryCacheRepository
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.remote.ConnectionScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

data class LibraryMetadataRefreshSummary(
    val queued: Int,
    val unsupported: Int,
    val failed: List<String>,
) {
    fun userMessage(): String = when {
        queued == 0 && unsupported == 0 && failed.isEmpty() -> "No libraries available to refresh."
        queued == 0 && failed.isEmpty() -> "$unsupported ${"library".pluralized(unsupported)} ${if (unsupported == 1) "does" else "do"} not support provider refresh."
        failed.isEmpty() && unsupported == 0 -> "Metadata refresh queued for $queued ${"library".pluralized(queued)}."
        failed.isEmpty() -> "Metadata refresh queued for $queued ${"library".pluralized(queued)}. $unsupported ${"library".pluralized(unsupported)} ${if (unsupported == 1) "does" else "do"} not support provider refresh."
        queued == 0 -> "Metadata refresh failed: ${failed.joinToString("; ")}"
        else -> "Metadata refresh queued for $queued ${"library".pluralized(queued)}. Failed: ${failed.joinToString("; ")}"
    }
}

@Singleton
class LibraryMetadataRefreshRepository @Inject constructor(
    private val adapters: Set<@JvmSuppressWildcards ProviderAdapter>,
    private val connectionRegistry: ConnectionRegistry,
    private val prefs: PreferencesManager,
    private val libraryCacheRepository: LibraryCacheRepository,
) {
    private val connectionMutex = Mutex()

    suspend fun refresh(libraries: List<Library>): LibraryMetadataRefreshSummary = withContext(Dispatchers.IO) {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        val targets = libraries
            .distinctBy { it.id }
            .mapNotNull { library -> library.toTarget(connections) }

        var queued = 0
        var unsupported = 0
        val failed = mutableListOf<String>()
        val refreshedConnectionIds = mutableSetOf<String>()
        val invalidatedAdapters = mutableSetOf<ProviderAdapter>()

        for (target in targets) {
            val adapter = adapters.firstOrNull { it.source == target.connection.source }
            if (adapter == null || !adapter.supportsLibraryMetadataRefresh) {
                unsupported += 1
                continue
            }

            val result = withConnectionContext(target.connection) {
                adapter.refreshLibraryMetadata(target.rawLibraryId)
            }
            result.onSuccess {
                queued += 1
                refreshedConnectionIds += target.connection.id
                if (invalidatedAdapters.add(adapter)) {
                    runCatching { adapter.invalidateCaches() }
                }
            }.onFailure { error ->
                failed += "${target.library.name}: ${error.message ?: error.javaClass.simpleName}"
            }
        }

        if (refreshedConnectionIds.isNotEmpty()) {
            runCatching {
                libraryCacheRepository.invalidateAndRefresh(refreshedConnectionIds.toList())
            }.onFailure { error ->
                failed += "Local cache refresh: ${error.message ?: error.javaClass.simpleName}"
            }
        }

        LibraryMetadataRefreshSummary(
            queued = queued,
            unsupported = unsupported,
            failed = failed,
        )
    }

    private fun Library.toTarget(connections: List<ProviderConnection>): RefreshTarget? {
        val connection = connectionId
            ?.takeIf { it.isNotBlank() }
            ?.let { id -> connections.find { it.id == id } }
            ?: connections.filter { it.source == source }.singleOrNull()
            ?: return null
        val rawLibraryId = rawLibraryId(connection.id).takeIf { it.isNotBlank() } ?: return null
        return RefreshTarget(this, connection, rawLibraryId)
    }

    private fun Library.rawLibraryId(connectionId: String): String {
        val prefix = "$connectionId::"
        return when {
            id.startsWith(prefix) -> id.removePrefix(prefix)
            "::" in id -> id.substringAfter("::")
            else -> id
        }
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

    private data class RefreshTarget(
        val library: Library,
        val connection: ProviderConnection,
        val rawLibraryId: String,
    )
}

private fun String.pluralized(count: Int): String = if (count == 1) this else "${this}s"
