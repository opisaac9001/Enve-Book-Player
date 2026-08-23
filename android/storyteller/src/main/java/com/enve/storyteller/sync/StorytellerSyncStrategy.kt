package com.enve.storyteller.sync

import android.util.Log
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import com.enve.storyteller.StorytellerProviderAdapter
import com.enve.core.data.sync.ProviderSyncStrategy
import com.enve.core.data.sync.ProviderSyncResult
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext

@Singleton
class StorytellerSyncStrategy @Inject constructor(
    private val adapter: StorytellerProviderAdapter,
    private val connectionRegistry: ConnectionRegistry,
    private val bookCacheDao: BookCacheDao,
) : ProviderSyncStrategy {

    override val id: String = "storyteller"
    override val displayName: String = "Storyteller"

    private val minSyncIntervalMs = 60_000L
    @Volatile private var lastSyncAtMs: Long? = null

    override suspend fun sync(force: Boolean, launchOptimized: Boolean): ProviderSyncResult {
        val now = System.currentTimeMillis()
        if (!force) {
            val last = lastSyncAtMs
            if (last != null && now - last < minSyncIntervalMs) return ProviderSyncResult.ZERO
        }
        lastSyncAtMs = now

        val storytellerConnectionIds = connectionRegistry.connections.first()
            .asSequence()
            .filter { it.enabled && it.source == BookSource.STORYTELLER }
            .map { it.id }
            .toSet()
        if (storytellerConnectionIds.isEmpty()) return ProviderSyncResult.ZERO

        val cached = runCatching { bookCacheDao.getInProgressOnce(limit = 50) }
            .getOrDefault(emptyList())
            .filter { it.source == BookSource.STORYTELLER.name }

        if (cached.isEmpty()) return ProviderSyncResult.ZERO

        var pulled = 0
        for (cachedBook in cached) {
            val book = cachedBook.toBook()
            val connectionId = book.connectionId?.takeIf(storytellerConnectionIds::contains) ?: continue
            val snapshot = withContext(ConnectionScope.asContextElement(connectionId)) {
                when (book.mediaType) {
                    AppMediaType.AUDIOBOOK -> adapter.fetchAudiobookProgress(book).getOrNull()
                    AppMediaType.EBOOK -> adapter.fetchEbookProgress(book).getOrNull()
                    else -> null
                }
            } ?: continue

            val localPercentage = cachedBook.readProgress
            if (snapshot.percentage <= localPercentage + 0.005f) continue

            runCatching {
                bookCacheDao.updateUnifiedProgress(
                    bookId = book.id,
                    connectionId = book.connectionId,
                    progress = snapshot.percentage,
                    currentTimeSec = snapshot.positionMs?.let { it / 1000 } ?: -1L,
                    locatorJson = snapshot.locatorJson,
                    nowMs = System.currentTimeMillis(),
                )
                pulled += 1
                Log.i(TAG, "Pulled ${book.title}: ${(snapshot.percentage * 100).toInt()}%")
            }
        }

        return ProviderSyncResult(pulled = pulled, pushed = 0)
    }

    private companion object { const val TAG = "StorytellerSyncStrategy" }
}
