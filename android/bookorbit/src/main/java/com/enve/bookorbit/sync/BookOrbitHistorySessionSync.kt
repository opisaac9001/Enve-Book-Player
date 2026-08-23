package com.enve.bookorbit.sync

import android.content.Context
import com.enve.bookorbit.BookOrbitRepository
import com.enve.core.data.history.HistorySessionRepository
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import com.enve.core.data.model.HistorySessionOrigin
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import java.time.Instant
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BookOrbitHistorySessionSync @Inject constructor(
    @ApplicationContext context: Context,
    private val repository: BookOrbitRepository,
    private val history: HistorySessionRepository,
) {
    private val receipts = context.getSharedPreferences(RECEIPTS_FILE, Context.MODE_PRIVATE)

    suspend fun submit(book: Book, session: HistorySession): Boolean {
        if (session.source != BookSource.BOOKORBIT ||
            session.origin != HistorySessionOrigin.LOCAL ||
            session.activeDurationSeconds < 10L
        ) {
            return false
        }
        val receipt = "${session.connectionId}:${session.id}"
        if (receipts.contains(receipt)) return false
        val endProgress = session.endProgress?.toDouble()
        val startProgress = session.startProgress
        val sessionEndProgress = session.endProgress
        val progressDelta = if (startProgress != null && sessionEndProgress != null) {
            (sessionEndProgress - startProgress).toDouble()
        } else {
            null
        }
        try {
            repository.saveReadingSession(
                book = book,
                sessionId = session.id,
                startedAt = Instant.ofEpochMilli(session.startTimeMs),
                endedAt = Instant.ofEpochMilli(session.endTimeMs),
                durationSeconds = session.activeDurationSeconds.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                progressDelta = progressDelta,
                endProgress = endProgress,
                positionSec = if (book.mediaType == AppMediaType.AUDIOBOOK && book.duration > 0L && endProgress != null) {
                    (book.duration * endProgress).toLong()
                } else {
                    null
                },
            ).getOrThrow()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return false
        }
        receipts.edit().putBoolean(receipt, true).apply()
        trimReceipts()
        return true
    }

    suspend fun retry(connectionId: String, booksByKey: Map<String, Book>): Int {
        var pushed = 0
        for (session in history.sessions.value.asReversed()) {
            if (session.connectionId != connectionId || session.origin != HistorySessionOrigin.LOCAL) continue
            val book = booksByKey[session.bookKey] ?: continue
            if (submit(book, session)) pushed += 1
        }
        return pushed
    }

    suspend fun pull(connectionId: String, book: Book): Int {
        val remote = repository.fetchReadingSessions(book).getOrThrow()
            .filter { it.durationSeconds > 0L }
            .map { record ->
                HistorySession(
                    id = "bookorbit:$connectionId:${record.id}",
                    bookId = book.id,
                    bookKey = book.uniqueKey,
                    connectionId = connectionId,
                    source = BookSource.BOOKORBIT,
                    mediaType = record.mediaType,
                    startTimeMs = record.startedAtMs,
                    endTimeMs = record.endedAtMs,
                    activeDurationSeconds = record.durationSeconds,
                    startProgress = record.endProgress?.let { end -> record.progressDelta?.let { end - it } },
                    endProgress = record.endProgress,
                    origin = HistorySessionOrigin.BOOKORBIT,
                )
            }
        return history.replaceBookOrbitSessions(
            connectionId = connectionId,
            bookKey = book.uniqueKey,
            sessions = remote,
        )
    }

    private fun trimReceipts() {
        if (receipts.all.size <= MAX_RECEIPTS) return
        val retained = receipts.all.keys.sorted().takeLast(MAX_RECEIPTS)
        receipts.edit().clear().apply {
            retained.forEach { putBoolean(it, true) }
        }.apply()
    }

    private companion object {
        const val RECEIPTS_FILE = "bookorbit_history_session_receipts"
        const val MAX_RECEIPTS = 5_000
    }
}
