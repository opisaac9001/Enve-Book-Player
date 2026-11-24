package com.enve.app.viewmodel

import com.enve.app.data.history.HistorySessionStore
import com.enve.app.data.local.ReaderDatabase
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.bookorbit.sync.BookOrbitHistorySessionSync
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.reader.ReadingSpeedTracker
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.util.UUID
import kotlin.math.roundToInt

internal class ReaderReadingSession(
    private val history: HistorySessionStore,
    private val grimmory: GrimmoryRepository,
    private val bookOrbitHistorySync: BookOrbitHistorySessionSync,
    private val database: ReaderDatabase,
    private val pace: ReadingSpeedTracker,
    private val applicationScope: CoroutineScope,
) {
    private var startedAtMs: Long? = null
    private var resumedAtMs: Long? = null
    private var accumulatedMs: Long = 0
    private var startProgress: Float? = null

    val isRunning: Boolean get() = resumedAtMs != null

    fun start(): Long {
        startedAtMs?.let { return it }
        pace.reset()
        val now = System.currentTimeMillis()
        startedAtMs = now
        resumedAtMs = now
        accumulatedMs = 0
        startProgress = null
        return now
    }

    fun recordStartProgress(startedAt: Long, progress: Float) {
        if (startedAtMs == startedAt) startProgress = progress
    }

    fun pause() {
        pace.pause()
        val resumed = resumedAtMs ?: return
        val now = System.currentTimeMillis()
        if (now > resumed) accumulatedMs += now - resumed
        resumedAtMs = null
    }

    fun resume() {
        if (startedAtMs == null || resumedAtMs != null) return
        resumedAtMs = System.currentTimeMillis()
    }

    suspend fun checkpoint(book: Book, endProgress: Float, totalPages: Int) {
        take(book, endProgress, totalPages)?.let { history.append(it) }
    }

    fun close(book: Book, endProgress: Float, totalPages: Int, endPage: Int) {
        val session = take(book, endProgress, totalPages) ?: return
        applicationScope.launch(Dispatchers.IO) {
            history.append(session)
            try {
                when (session.source) {
                    BookSource.GRIMMORY -> {
                        val fileType = database.bookCacheDao().getById(session.bookId)?.primaryFileType
                        withSessionConnection(session.connectionId) {
                            grimmory.createReadingSession(
                                fileType = fileType,
                                bookId = session.bookId,
                                startTime = Instant.ofEpochMilli(session.startTimeMs),
                                endTime = Instant.ofEpochMilli(session.endTimeMs),
                                durationMs = session.activeDurationSeconds * 1_000L,
                                mediaType = AppMediaType.EBOOK,
                                startProgress = session.startProgress,
                                endProgress = session.endProgress,
                                endLocation = endPage.takeIf { it > 0 }?.toString(),
                            ).getOrThrow()
                        }
                    }
                    BookSource.BOOKORBIT -> withSessionConnection(session.connectionId) {
                        bookOrbitHistorySync.submit(book = book, session = session)
                    }
                    else -> Unit
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
    }

    private fun take(book: Book, endProgress: Float, totalPages: Int): HistorySession? {
        val startedAt = startedAtMs ?: return null
        pause()
        val durationMs = accumulatedMs
        val endAt = System.currentTimeMillis()
        startedAtMs = null
        resumedAtMs = null
        accumulatedMs = 0

        if (durationMs < 5_000L) return null
        val initialProgress = startProgress
        val pagesRead = initialProgress?.let { start ->
            val delta = endProgress - start
            if (totalPages > 0 && delta > 0f) {
                (delta * totalPages).roundToInt().coerceAtLeast(1)
            } else {
                null
            }
        }
        startProgress = null
        return HistorySession(
            id = UUID.randomUUID().toString(),
            bookId = book.id,
            bookKey = "${book.connectionId ?: book.source.name}:${book.id}",
            connectionId = book.connectionId,
            source = book.source,
            mediaType = AppMediaType.EBOOK,
            startTimeMs = startedAt,
            endTimeMs = endAt,
            activeDurationSeconds = durationMs / 1_000L,
            startProgress = initialProgress,
            endProgress = endProgress,
            pagesRead = pagesRead,
        )
    }

    private suspend fun withSessionConnection(connectionId: String?, block: suspend () -> Unit) {
        if (connectionId == null) {
            block()
        } else {
            withContext(ConnectionScope.asContextElement(connectionId)) { block() }
        }
    }
}
