package com.enve.app.data.sync

import com.enve.app.playback.audioLocalPercentage
import com.enve.app.playback.audioLocalStartSeconds
import com.enve.app.playback.forAudioPlayback
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.PendingProgressPushDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AudiobookProgressPushService @Inject constructor(
    private val books: BookCacheDao,
    private val pending: PendingProgressPushDao,
    private val rewindTracker: RemoteRewindTracker,
    private val writerOrder: com.enve.core.data.sync.AudiobookProgressWriteCoordinator,
    private val checkpointOrder: com.enve.core.data.sync.AudiobookCheckpointOrder,
) {
    data class Command(
        val progress: Float,
        val positionSec: Long,
        val finished: Boolean,
        val hidden: Boolean,
        val status: String?,
    )

    suspend fun push(
        book: Book,
        currentTimeSec: Long,
        progressFraction: Float,
        canWrite: () -> Boolean = { true },
        acknowledgePending: Boolean = true,
        recordOutboundEcho: Boolean = true,
        write: suspend (Book, Long, Float) -> Result<Unit>,
    ): Result<Unit> = ordered(book) {
        if (!canWrite()) return@ordered Result.success(Unit)
        val cachedRow = books.getByCacheKey(book.uniqueKey)
            ?.takeIf { it.source == book.source.name && it.connectionId == book.connectionId }
        val pendingRow = pending.get(book.id, book.source.name, book.connectionId.orEmpty())
        val cached = cachedRow?.toBook()?.forAudioPlayback()
        val checkpoint = (cached ?: book.forAudioPlayback()).copy(
            episodeId = book.episodeId,
            podcastLibraryItemId = book.podcastLibraryItemId,
            podcastEnclosureUrl = book.podcastEnclosureUrl,
            podcastName = book.podcastName,
        )
        val position = cached?.let(::audioLocalStartSeconds) ?: currentTimeSec.coerceAtLeast(0L)
        val progress = cached?.let(::audioLocalPercentage) ?: progressFraction.coerceIn(0f, 1f)
        if (!canWrite()) return@ordered Result.success(Unit)
        val result = write(checkpoint, position, progress)
        if (result.isSuccess && canWrite()) {
            if (acknowledgePending && cachedRow != null && pendingRow?.mediaType == "AUDIOBOOK") {
                books.acknowledgeAudiobookProgress(cachedRow, pendingRow.createdAt, pendingRow.percentage)
            }
            if (recordOutboundEcho) {
                rewindTracker.recordOutboundWrite(
                    key = RemoteProgressWriteKey.of(checkpoint),
                    percentage = progress,
                    positionMs = position * 1000L,
                    locatorJson = null,
                )
            }
        }
        result
    }

    suspend fun <T> ordered(book: Book, action: suspend () -> T): T =
        writerOrder.ordered(book.source, book.connectionId, action)

    suspend fun command(
        book: Book,
        canWrite: () -> Boolean,
        transform: (com.enve.core.data.local.CachedBook) -> Command,
        write: suspend () -> Result<Unit>,
    ): Result<Unit> {
        val sequence = checkpointOrder.newSequence()
        return ordered(book) {
            val expected = books.getByCacheKey(book.uniqueKey)
                ?.takeIf { it.source == book.source.name && it.connectionId == book.connectionId }
            val dirty = pending.get(book.id, book.source.name, book.connectionId.orEmpty())?.takeIf { it.mediaType == "AUDIOBOOK" }
            val result = if (canWrite()) write() else Result.success(Unit)
            if (result.isSuccess && expected != null) {
                val command = transform(expected)
                checkpointOrder.serialized { state ->
                    if (!state.isSuperseded(book.uniqueKey, sequence)) {
                        val updated = books.commitAudiobookCommandIfUnchanged(expected, command.progress, command.positionSec,
                            command.finished, command.hidden, command.status, System.currentTimeMillis(),
                            dirty?.createdAt, dirty?.percentage ?: 0f)
                        if (updated > 0) state.recordApplied(book.uniqueKey, sequence)
                    }
                }
            }
            result
        }
    }
}
