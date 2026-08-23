package com.enve.app.playback

import com.enve.audiobookshelf.AudiobookshelfRepository
import com.enve.bookorbit.sync.BookOrbitHistorySessionSync
import com.enve.silo.SiloRepository
import com.enve.app.data.history.HistorySessionStore
import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.ReadingSessionRequest
import com.enve.app.data.repository.grimmory.grimmoryServerBookId
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import com.enve.core.data.remote.ConnectionScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.round
import kotlin.math.roundToLong

private const val ABS_SESSION_SYNC_INTERVAL_MS = 30_000L

@Singleton
class PlayerSessionService @Inject constructor(
    private val api: GrimmoryApi,
    private val audiobookshelfRepository: AudiobookshelfRepository,
    private val bookOrbitHistorySync: BookOrbitHistorySessionSync,
    private val siloRepository: SiloRepository,
    private val history: HistorySessionStore,
) {
    private val mutex = Mutex()
    private var active: ActiveSession? = null
    private var lastResumeRealtimeMs: Long? = null

    val hasActiveSession: Boolean
        get() = active != null

    suspend fun start(
        book: Book,
        positionSec: Long,
        durationSec: Long,
        providerSessionId: String? = null,
    ) {
        if (book.mediaType != AppMediaType.AUDIOBOOK && book.mediaType != AppMediaType.PODCAST) return
        val sessionToClose = mutex.withLock {
            val current = active
            if (current?.bookKey == book.uniqueKey) {
                current.lastPositionSec = positionSec
                current.durationSec = durationSec
                if (!providerSessionId.isNullOrBlank() && book.source == BookSource.AUDIOBOOKSHELF) {
                    current.absSessionId = providerSessionId
                }
                return@withLock null
            }
            val startedAtMs = System.currentTimeMillis()
            active = ActiveSession(
                book = book,
                bookKey = book.uniqueKey,
                startedAtMs = startedAtMs,
                durationSec = durationSec.coerceAtLeast(0),
                startPositionSec = positionSec.coerceAtLeast(0),
                lastPositionSec = positionSec.coerceAtLeast(0),
                absSessionId = providerSessionId.takeIf { book.source == BookSource.AUDIOBOOKSHELF && !it.isNullOrBlank() },
                lastAbsSyncAtMs = startedAtMs,
            )
            lastResumeRealtimeMs = null
            current
        }
        sessionToClose?.let { submitSession(it) }
    }

    suspend fun markPlaybackChanged(isPlaying: Boolean, positionSec: Long, durationSec: Long) {
        var absSync: AbsSessionSnapshot? = null
        mutex.withLock {
            val session = active ?: return
            val now = System.currentTimeMillis()
            session.lastPositionSec = positionSec.coerceAtLeast(0)
            session.durationSec = durationSec.coerceAtLeast(0)
            if (isPlaying) {
                if (lastResumeRealtimeMs == null) {
                    lastResumeRealtimeMs = now
                } else {
                    accumulateLocked(now)
                }
                if (session.shouldSyncAbs(now)) {
                    session.lastAbsSyncAtMs = now
                    absSync = session.absSnapshot()
                }
            } else {
                accumulateLocked(now)
                lastResumeRealtimeMs = null
            }
        }
        absSync?.let { syncAbsSession(it) }
    }

    suspend fun close(positionSec: Long, durationSec: Long) {
        val session = mutex.withLock {
            val current = active ?: return@withLock null
            current.lastPositionSec = positionSec.coerceAtLeast(0)
            current.durationSec = durationSec.coerceAtLeast(0)
            accumulateLocked()
            lastResumeRealtimeMs = null
            active = null
            current
        } ?: return
        submitSession(session)
    }

    private fun accumulateLocked(now: Long = System.currentTimeMillis()) {
        val resumedAt = lastResumeRealtimeMs ?: return
        if (now > resumedAt) {
            active?.timeListenedMs = (active?.timeListenedMs ?: 0L) + now - resumedAt
        }
        lastResumeRealtimeMs = now
    }

    private suspend fun submitSession(session: ActiveSession) {
        val listenedMs = session.timeListenedMs.coerceAtLeast(0)
        val endAtMs = System.currentTimeMillis()
        val historySession = if (listenedMs >= 1_000L) {
            HistorySession(
                id = UUID.randomUUID().toString(),
                bookId = session.book.id,
                bookKey = session.bookKey,
                connectionId = session.book.connectionId,
                source = session.book.source,
                mediaType = session.book.mediaType,
                startTimeMs = session.startedAtMs,
                endTimeMs = endAtMs,
                activeDurationSeconds = listenedMs / 1_000L,
                startProgress = progress(session.startPositionSec, session.durationSec),
                endProgress = progress(session.lastPositionSec, session.durationSec),
            ).also { history.append(it) }
        } else {
            null
        }

        if (session.book.source == BookSource.SILO) {

            withConnection(session.book) { siloRepository.stopPlaybackSession(session.book) }
        }

        session.absSnapshot()?.let {
            closeAbsSession(it)
            return
        }

        if (listenedMs < 1_000L) return
        val startInstant = Instant.ofEpochMilli(session.startedAtMs)
        val endInstant = Instant.ofEpochMilli(endAtMs)
        when (session.book.source) {
            BookSource.BOOKORBIT -> {
                withConnection(session.book) {
                    historySession?.let { bookOrbitHistorySync.submit(session.book, it) }
                }
            }
            BookSource.GRIMMORY -> {
                try {
                    val bookId = session.book.id.grimmoryServerBookId().toLongOrNull() ?: return
                    val durationSeconds = (listenedMs / 1_000.0)
                        .roundToLong()
                        .coerceAtMost(Int.MAX_VALUE.toLong())
                        .toInt()
                    val startProgress = progress(session.startPositionSec, session.durationSec)?.let { round(it * 1_000f) / 10f }
                    val endProgress = progress(session.lastPositionSec, session.durationSec)?.let { round(it * 1_000f) / 10f }
                    val request: suspend () -> Unit = {
                        api.createReadingSession(
                            ReadingSessionRequest(
                                bookId = bookId,
                                bookType = "AUDIOBOOK",
                                startTime = startInstant.toString(),
                                endTime = endInstant.toString(),
                                durationSeconds = durationSeconds,
                                durationFormatted = formatReadingSessionDuration(durationSeconds),
                                startProgress = startProgress,
                                endProgress = endProgress,
                                progressDelta = if (startProgress != null && endProgress != null) {
                                    endProgress - startProgress
                                } else {
                                    null
                                },
                                startLocation = (session.startPositionSec * 1_000L).toString(),
                                endLocation = (session.lastPositionSec * 1_000L).toString(),
                            )
                        )
                    }
                    session.book.connectionId?.let { connectionId ->
                        withContext(ConnectionScope.asContextElement(connectionId)) { request() }
                    } ?: request()
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                }
            }
            else -> Unit
        }
    }

    private fun progress(positionSec: Long, durationSec: Long): Float? =
        if (durationSec > 0L) {
            (positionSec.toFloat() / durationSec.toFloat()).coerceIn(0f, 1f)
        } else {
            null
        }

    private fun formatReadingSessionDuration(durationSeconds: Int): String {
        val hours = durationSeconds / 3_600
        val minutes = durationSeconds % 3_600 / 60
        val seconds = durationSeconds % 60
        return buildList {
            if (hours > 0) add("${hours}h")
            if (minutes > 0 || hours > 0) add("${minutes}m")
            add("${seconds}s")
        }.joinToString(" ")
    }

    private suspend fun syncAbsSession(snapshot: AbsSessionSnapshot) {
        if (snapshot.durationSec <= 0L) return
        val result = withConnection(snapshot.book) {
            audiobookshelfRepository.syncPlaybackSession(
                sessionId = snapshot.sessionId,
                currentTimeSec = snapshot.positionSec,
                timeListenedMs = snapshot.timeListenedMs,
                durationSec = snapshot.durationSec,
            )
        }
        if (result.isFailure) {
            syncAbsProgressDirectly(snapshot)
        }
    }

    private suspend fun closeAbsSession(snapshot: AbsSessionSnapshot) {
        val result = withConnection(snapshot.book) {
            audiobookshelfRepository.closePlaybackSession(
                sessionId = snapshot.sessionId,
                currentTimeSec = snapshot.positionSec,
                timeListenedMs = snapshot.timeListenedMs,
                durationSec = snapshot.durationSec,
            )
        }
        if (result.isFailure) {
            syncAbsProgressDirectly(snapshot)
        }
    }

    private suspend fun syncAbsProgressDirectly(snapshot: AbsSessionSnapshot) {
        if (snapshot.durationSec <= 0L) return
        val progress = (snapshot.positionSec.toFloat() / snapshot.durationSec.toFloat()).coerceIn(0f, 1f)
        withConnection(snapshot.book) {
            audiobookshelfRepository.syncAudiobookProgress(snapshot.book, snapshot.positionSec, progress)
        }
    }

    private suspend fun <T> withConnection(book: Book, block: suspend () -> T): T {
        val connectionId = book.connectionId ?: return block()
        return withContext(ConnectionScope.asContextElement(connectionId)) { block() }
    }

    private data class ActiveSession(
        val book: Book,
        val bookKey: String,
        val startedAtMs: Long,
        var durationSec: Long,
        val startPositionSec: Long,
        var lastPositionSec: Long,
        var absSessionId: String? = null,
        var lastAbsSyncAtMs: Long = startedAtMs,
        var timeListenedMs: Long = 0L,
    ) {
        fun shouldSyncAbs(nowMs: Long): Boolean =
            absSessionId != null &&
                durationSec > 0L &&
                nowMs - lastAbsSyncAtMs >= ABS_SESSION_SYNC_INTERVAL_MS

        fun absSnapshot(): AbsSessionSnapshot? {
            val sessionId = absSessionId ?: return null
            return AbsSessionSnapshot(
                book = book,
                sessionId = sessionId,
                positionSec = lastPositionSec,
                durationSec = durationSec,
                timeListenedMs = timeListenedMs,
            )
        }
    }

    private data class AbsSessionSnapshot(
        val book: Book,
        val sessionId: String,
        val positionSec: Long,
        val durationSec: Long,
        val timeListenedMs: Long,
    )
}
