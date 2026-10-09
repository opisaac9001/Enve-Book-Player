package com.enve.app.playback

import androidx.room.withTransaction
import com.enve.app.data.local.ReaderDatabase
import com.enve.app.data.sync.SyncCoordinator
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.core.data.sync.AudiobookCheckpointOrder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PlayerProgressService @Inject constructor(
    private val syncCoordinator: SyncCoordinator,
    private val database: ReaderDatabase,
    private val bookCache: BookCacheDao,
    private val openProgress: PlaybackOpenProgressResolver,
    private val pending: com.enve.core.data.local.PendingProgressPushDao,
    private val serverSync: com.enve.core.data.local.ProfileServerSyncStore,
    private val checkpointOrder: AudiobookCheckpointOrder,
) {
    data class Checkpoint(
        val key: String,
        val mediaId: String,
        val bookId: String?,
        val positionMs: Long,
        val durationMs: Long,
        val capturedAtMs: Long,
        val capturedElapsedMs: Long,
        val sequence: Long,
    )

    data class PersistedPlaybackProgress(
        val book: Book,
        val currentTimeSec: Long,
        val progressFraction: Float,
    )

    sealed interface SaveResult {
        data class Saved(val progress: PersistedPlaybackProgress) : SaveResult
        data object Superseded : SaveResult
        data class Retry(val error: Exception? = null) : SaveResult
    }

    private val writer = PlaybackCheckpointWriter(checkpointOrder, ::writeCheckpoint)

    fun sync(book: Book, currentTimeSec: Long, progressFraction: Float) {
        if (openProgress.shouldHoldPush(book)) return
        syncCoordinator.pushProgress(book, currentTimeSec, progressFraction)
    }

    fun syncImmediate(book: Book, currentTimeSec: Long, progressFraction: Float) {
        if (openProgress.shouldHoldPush(book)) return
        syncCoordinator.pushProgress(book, currentTimeSec, progressFraction, forceImmediate = true)
    }

    fun capturePlayback(
        mediaId: String?,
        bookId: String? = null,
        positionMs: Long,
        durationMs: Long,
        capturedAtMs: Long = System.currentTimeMillis(),
        capturedElapsedMs: Long = System.nanoTime() / 1_000_000L,
    ): Checkpoint? {
        val id = mediaId ?: return null
        val key = AutoMediaBrowserHelper.cacheKeyFrom(id) ?: return null
        return Checkpoint(key, id, bookId, positionMs.coerceAtLeast(0L), durationMs.coerceAtLeast(0L),
            capturedAtMs, capturedElapsedMs, checkpointOrder.capture(key))
    }

    suspend fun persistPlayback(
        mediaId: String?,
        bookId: String?,
        positionMs: Long,
        durationMs: Long,
        force: Boolean = false,
        capturedAtMs: Long = System.currentTimeMillis(),
    ): SaveResult {
        val checkpoint = capturePlayback(mediaId, bookId, positionMs, durationMs, capturedAtMs)
            ?: return SaveResult.Retry()
        return persistCheckpoint(checkpoint, force)
    }

    suspend fun persistCheckpoint(checkpoint: Checkpoint, force: Boolean = false): SaveResult =
        withContext(Dispatchers.IO) { writer.persist(checkpoint, force) }

    private suspend fun writeCheckpoint(checkpoint: Checkpoint): PersistedPlaybackProgress? = database.withTransaction {
        val cached = bookCache.getByCacheKey(checkpoint.key) ?: return@withTransaction null
        if (checkpoint.bookId != null && cached.id != checkpoint.bookId) return@withTransaction null
        val positionSec = checkpoint.positionMs / 1000L
        val durationSec = (checkpoint.durationMs / 1000L).takeIf { it > 0L }
            ?: cached.duration.takeIf { it > 0L } ?: 0L
        val progress = if (durationSec > 0L) {
            (positionSec.toFloat() / durationSec).coerceIn(0f, 1f)
        } else if (positionSec == 0L) 0f else cached.readProgress
        val nowMs = checkpoint.capturedAtMs
        if (bookCache.updateAudiobookProgress(checkpoint.key, progress, positionSec, nowMs) == 0) {
            return@withTransaction null
        }
        val book = cached.toBook().forAudioPlayback().copy(
            currentTime = positionSec,
            readProgress = progress,
            lastReadTime = nowMs,
            duration = durationSec.takeIf { it > 0L } ?: cached.duration,
        )
        if (serverSync.isEnabled && book.source != com.enve.core.data.model.BookSource.LOCAL && !openProgress.shouldHoldPush(book)) {
            val existing = pending.get(book.id, book.source.name, book.connectionId.orEmpty())
            pending.upsert(com.enve.core.data.local.PendingProgressPush(
                bookId = book.id,
                source = book.source.name,
                connectionKey = book.connectionId.orEmpty(),
                mediaType = com.enve.core.data.model.AppMediaType.AUDIOBOOK.name,
                percentage = progress,
                isFinished = progress >= 1f,
                createdAt = maxOf(nowMs, (existing?.createdAt ?: 0L) + 1L),
            ))
        }
        PersistedPlaybackProgress(book, positionSec, progress)
    }
}
