package com.enve.silo.sync

import android.util.Log
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.sync.ProviderSyncResult
import com.enve.core.data.sync.ProviderSyncStrategy
import com.enve.silo.SiloRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SiloSyncStrategy @Inject constructor(
    private val repository: SiloRepository,
    private val bookCacheDao: BookCacheDao,
    private val connectionRegistry: ConnectionRegistry,
) : ProviderSyncStrategy {
    override val id: String = "silo"
    override val displayName: String = "Silo"

    private val minSyncIntervalMs = 60_000L
    @Volatile private var lastSyncAtMs: Long? = null

    override suspend fun sync(force: Boolean, launchOptimized: Boolean): ProviderSyncResult {
        val now = System.currentTimeMillis()
        if (!force) {
            val last = lastSyncAtMs
            if (last != null && now - last < minSyncIntervalMs) return ProviderSyncResult.ZERO
        }

        val connections = connectionRegistry.connections.first()
            .filter { it.enabled && it.source == BookSource.SILO }
        if (connections.isEmpty()) return ProviderSyncResult.ZERO

        var pulled = 0
        var failed = false
        for (connection in connections) {
            try {
                val books = withContext(ConnectionScope.asContextElement(connection.id)) {
                    repository.getContinue().getOrThrow()
                }
                val nowMs = System.currentTimeMillis()
                books.distinctBy { it.uniqueKey }.forEach { book ->
                    val scoped = book.copy(
                        source = BookSource.SILO,
                        connectionId = connection.id,
                        libraryId = book.libraryId?.let { "${connection.id}::${it.substringAfter("::")}" },
                    )
                    if (bookCacheDao.insertIfAbsent(scoped.toCachedBook(nowMs)) != -1L) {
                        pulled++
                    } else {
                        pulled += bookCacheDao.applyRemoteProgress(
                            cacheKey = scoped.uniqueKey,
                            source = BookSource.SILO.name,
                            progress = scoped.readProgress,
                            ebookProgress = scoped.epubProgress,
                            currentTimeSec = scoped.currentTime,
                            locatorJson = scoped.epubLocator,
                            finished = scoped.isFinished,
                            readStatus = scoped.serverReadStatus,
                            updatedAt = scoped.lastReadTime,
                        )
                    }
                }
                connectionRegistry.setLastSynced(connection.id, System.currentTimeMillis())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                failed = true
                Log.w(TAG, "Silo sync failed for connection=${connection.id}: ${e.message}")
            }
        }
        if (!failed) lastSyncAtMs = now
        return ProviderSyncResult(pulled = pulled, pushed = 0, failedBackends = if (failed) listOf(displayName) else emptyList())
    }

    private companion object { const val TAG = "SiloSyncStrategy" }
}
