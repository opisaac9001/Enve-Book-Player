package com.enve.app.playback

import com.enve.app.data.sync.SyncCoordinator
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

private const val PLAYBACK_PROGRESS_PERSIST_INTERVAL_MS = 5_000L

@Singleton
class PlayerProgressService @Inject constructor(
    private val syncCoordinator: SyncCoordinator,
    private val bookCache: BookCacheDao,
) {
    private val lastPersistAtMs = ConcurrentHashMap<String, Long>()

    data class PersistedPlaybackProgress(
        val book: Book,
        val currentTimeSec: Long,
        val progressFraction: Float,
    )

    fun sync(book: Book, currentTimeSec: Long, progressFraction: Float) {
        syncCoordinator.pushProgress(book, currentTimeSec, progressFraction)
    }

    fun syncImmediate(book: Book, currentTimeSec: Long, progressFraction: Float) {
        syncCoordinator.pushProgress(book, currentTimeSec, progressFraction, forceImmediate = true)
    }

    suspend fun persistPlayback(
        mediaId: String?,
        bookId: String?,
        positionMs: Long,
        durationMs: Long,
        force: Boolean = false,
    ): PersistedPlaybackProgress? = withContext(Dispatchers.IO) {
        val positionSec = positionMs.coerceAtLeast(0L) / 1000L
        if (positionSec <= 0L) return@withContext null

        val cacheKey = mediaId?.let(AutoMediaBrowserHelper::cacheKeyFrom)
        val progressKey = cacheKey ?: bookId ?: return@withContext null
        val nowMs = System.currentTimeMillis()
        if (!force && nowMs - (lastPersistAtMs[progressKey] ?: 0L) < PLAYBACK_PROGRESS_PERSIST_INTERVAL_MS) {
            return@withContext null
        }

        val cached = cacheKey?.let { bookCache.getByCacheKey(it) } ?: bookId?.let { bookCache.getById(it) }
        val durationSec = (durationMs.coerceAtLeast(0L) / 1000L).takeIf { it > 0L }
            ?: cached?.duration?.takeIf { it > 0L }
            ?: 0L
        val progress = when {
            durationSec > 0L -> positionSec.toFloat() / durationSec.toFloat()
            cached != null -> cached.readProgress
            else -> 0f
        }.coerceIn(0f, 1f)

        val updatedRows = cached?.let {
            bookCache.updateUnifiedProgress(
                bookId = it.id,
                connectionId = it.connectionId,
                progress = progress,
                currentTimeSec = positionSec,
                locatorJson = null,
                nowMs = nowMs,
            )
        } ?: 0
        if (updatedRows == 0 && bookId != null) {
            bookCache.updateUnifiedProgressById(
                bookId = bookId,
                progress = progress,
                currentTimeSec = positionSec,
                locatorJson = null,
                nowMs = nowMs,
            )
        }

        val persisted = cached?.toBook() ?: bookId?.let { bookCache.getById(it)?.toBook() }
        lastPersistAtMs[progressKey] = nowMs
        persisted?.let {
            PersistedPlaybackProgress(
                book = it.copy(
                    currentTime = positionSec,
                    duration = durationSec.takeIf { sec -> sec > 0L } ?: it.duration,
                ),
                currentTimeSec = positionSec,
                progressFraction = progress,
            )
        }
    }
}
