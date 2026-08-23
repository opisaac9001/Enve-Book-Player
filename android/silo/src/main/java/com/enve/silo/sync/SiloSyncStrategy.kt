package com.enve.silo.sync

import android.util.Log
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.sync.ProviderSyncResult
import com.enve.core.data.sync.ProviderSyncStrategy
import com.enve.silo.SiloProviderAdapter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SiloSyncStrategy @Inject constructor(
    private val adapter: SiloProviderAdapter,
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
        lastSyncAtMs = now

        val connections = connectionRegistry.connections.first()
            .filter { it.enabled && it.source == BookSource.SILO }
        if (connections.isEmpty()) return ProviderSyncResult.ZERO

        var pulled = 0
        for (connection in connections) {
            try {
                val books = withContext(ConnectionScope.asContextElement(connection.id)) {
                    adapter.getContinueListening().getOrDefault(emptyList()) +
                        adapter.getContinueReading().getOrDefault(emptyList())
                }
                val nowMs = System.currentTimeMillis()
                books.distinctBy { it.uniqueKey }.forEach { book ->
                    bookCacheDao.upsert(
                        listOf(
                            book.copy(
                                source = BookSource.SILO,
                                connectionId = connection.id,
                            ).toCachedBook(nowMs),
                        ),
                    )
                    pulled += 1
                }
                connectionRegistry.setLastSynced(connection.id, System.currentTimeMillis())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Silo sync failed for connection=${connection.id}: ${e.message}")
            }
        }
        return ProviderSyncResult(pulled = pulled, pushed = 0)
    }

    private companion object { const val TAG = "SiloSyncStrategy" }
}
