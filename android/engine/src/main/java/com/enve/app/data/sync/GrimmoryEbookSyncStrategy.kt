package com.enve.app.data.sync

import android.util.Log
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.app.data.repository.AggregatorRepository
import com.enve.core.data.sync.ProviderSyncStrategy
import com.enve.core.data.sync.ProviderSyncResult
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class GrimmoryEbookSyncStrategy @Inject constructor(
    private val aggregatorRepository: AggregatorRepository,
    private val bookCacheDao: BookCacheDao,
) : ProviderSyncStrategy {

    override val id: String = "grimmory-ebook"
    override val displayName: String = "Grimmory (Ebook)"

    private val minSyncIntervalMs = 60_000L
    @Volatile private var lastSyncAtMs: Long? = null

    override suspend fun sync(force: Boolean, launchOptimized: Boolean): ProviderSyncResult {
        val now = System.currentTimeMillis()
        if (!force) {
            val last = lastSyncAtMs
            if (last != null && now - last < minSyncIntervalMs) return ProviderSyncResult.ZERO
        }
        lastSyncAtMs = now

        val limit = if (launchOptimized) 12 else 40
        val cached = runCatching { bookCacheDao.getInProgressOnce(limit = limit) }
            .getOrDefault(emptyList())
            .filter { it.source == BookSource.GRIMMORY.name && it.mediaType == AppMediaType.EBOOK.name }

        if (cached.isEmpty()) return ProviderSyncResult.ZERO

        var pulled = 0
        for (cachedBook in cached) {
            val book = cachedBook.toBook()
            val snapshot = aggregatorRepository.fetchEbookProgress(book).getOrNull() ?: continue

            val localPercentage = cachedBook.readProgress
            val progressAdvanced = snapshot.percentage > localPercentage + 0.005f
            if (!snapshot.finished && !progressAdvanced) continue

            runCatching {
                val nowMs = System.currentTimeMillis()
                if (snapshot.finished) {
                    bookCacheDao.updateFinishedStatus(
                        bookId = book.id,
                        connectionId = book.connectionId,
                        finished = true,
                        nowMs = nowMs,
                    )
                } else {
                    bookCacheDao.updateUnifiedProgress(
                        bookId = book.id,
                        connectionId = book.connectionId,
                        progress = snapshot.percentage,
                        currentTimeSec = -1L,
                        locatorJson = snapshot.locatorJson,
                        nowMs = nowMs,
                    )
                }
                pulled += 1
                Log.i(TAG, "Pulled ${book.title}: ${(snapshot.percentage * 100).toInt()}%${if (snapshot.finished) " (finished)" else ""}")
            }
        }

        return ProviderSyncResult(pulled = pulled, pushed = 0)
    }

    private companion object { const val TAG = "GrimmoryEbookSyncStrategy" }
}
