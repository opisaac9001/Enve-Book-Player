package com.enve.app.data.sync

import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.local.PendingProgressPushDao
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.util.runSuspendCatching
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ProgressResetService @Inject constructor(
    private val books: BookCacheDao,
    private val pending: PendingProgressPushDao,
    private val audiobookProgressPush: AudiobookProgressPushService,
) {
    suspend fun reset(book: Book, syncEnabled: Boolean, write: suspend () -> Result<Unit>): Result<Unit> {
        val audio = book.mediaType == AppMediaType.AUDIOBOOK || book.mediaType == AppMediaType.PODCAST
        if (audio) resetAudioLocally(book) else resetEbookLocally(book)
        if (!syncEnabled) return Result.success(Unit)
        val result = audiobookProgressPush.ordered(book) { runSuspendCatching { write().getOrThrow() } }
        if (result.isFailure && book.source != BookSource.LOCAL) {
            queue(book, if (audio) AppMediaType.AUDIOBOOK else AppMediaType.EBOOK)
        }
        return result
    }

    private suspend fun resetAudioLocally(book: Book) {
        audiobookProgressPush.command(
            book,
            canWrite = { true },
            transform = { cached -> AudiobookProgressPushService.Command(0f, 0L, false, cached.hideFromContinue, null) },
            write = { Result.success(Unit) },
        )
    }

    private suspend fun resetEbookLocally(book: Book) {
        val now = System.currentTimeMillis()
        books.updateUnifiedProgress(book.id, book.connectionId, progress = 0f, currentTimeSec = 0L, locatorJson = null, nowMs = now)
        books.updateEpubProgress(book.id, book.connectionId, locatorJson = null, progress = 0f)
        books.updateFinishedStatus(book.id, book.connectionId, finished = false, nowMs = now)
    }

    private suspend fun queue(book: Book, mediaType: AppMediaType) {
        val connectionKey = book.connectionId.orEmpty()
        val existing = pending.get(book.id, book.source.name, connectionKey)
        val now = System.currentTimeMillis()
        pending.upsert(
            PendingProgressPush(
                bookId = book.id,
                source = book.source.name,
                connectionKey = connectionKey,
                mediaType = mediaType.name,
                percentage = 0f,
                isFinished = false,
                createdAt = maxOf(now, (existing?.createdAt ?: 0L) + 1L),
                attempts = (existing?.attempts ?: 0) + 1,
                lastAttemptAt = now,
            ),
        )
    }
}
