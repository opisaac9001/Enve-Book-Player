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
class GrimmoryAudiobookSyncStrategy @Inject constructor(
    private val aggregatorRepository: AggregatorRepository,
    private val bookCacheDao: BookCacheDao,
) : ProviderSyncStrategy {

    override val id: String = "grimmory-audiobook"
    override val displayName: String = "Grimmory (Audiobook)"

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
            .filter { it.source == BookSource.GRIMMORY.name && it.mediaType == AppMediaType.AUDIOBOOK.name }

        val localKeys = cached.map { "${it.connectionId ?: it.source}:${it.id}" }.toSet()
        val serverOnly = try {
            aggregatorRepository.getHomeSnapshot().getOrNull()?.continueListening.orEmpty()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            emptyList()
        }
            .filter { it.source == BookSource.GRIMMORY && it.mediaType == AppMediaType.AUDIOBOOK }
            .filter { "${it.connectionId ?: it.source.name}:${it.id}" !in localKeys }
            .take(20)

        if (cached.isEmpty() && serverOnly.isEmpty()) return ProviderSyncResult.ZERO

        val candidates = LinkedHashMap<String, com.enve.core.data.model.Book>()
        cached.forEach { candidates[it.id] = it.toBook() }
        serverOnly.forEach { candidates.putIfAbsent(it.id, it) }

        var pulled = 0
        for (book in candidates.values) {
            val snapshot = aggregatorRepository.fetchAudiobookProgress(book).getOrNull() ?: continue

            val localRow = bookCacheDao.getById(book.id)
            val decision = ProgressResolutionPolicy.resolve(
                localPercentage = localRow?.readProgress ?: 0f,
                localUpdatedAt = localRow?.lastReadTime?.takeIf { it > 0L },
                remote = snapshot,
            )
            if (!snapshot.finished && decision != ProgressResolutionPolicy.Decision.PULL) continue
            if (snapshot.finished && decision == ProgressResolutionPolicy.Decision.PUSH) continue

            runCatching {
                val nowMs = System.currentTimeMillis()

                if (snapshot.finished) {
                    bookCacheDao.updateFinishedStatusById(bookId = book.id, finished = true, nowMs = nowMs)
                } else {
                    bookCacheDao.updateUnifiedProgressById(
                        bookId = book.id,
                        progress = snapshot.percentage,
                        currentTimeSec = snapshot.positionMs?.let { it / 1000 } ?: -1L,
                        locatorJson = null,
                        nowMs = nowMs,
                    )
                }
                pulled += 1
                Log.i(TAG, "Pulled ${book.title}: ${(snapshot.percentage * 100).toInt()}%${if (snapshot.finished) " (finished)" else ""}")
            }
        }

        return ProviderSyncResult(pulled = pulled, pushed = 0)
    }

    private companion object { const val TAG = "GrimmoryAudiobookSyncStrategy" }
}
