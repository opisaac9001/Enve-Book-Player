package com.enve.app.playback

import com.enve.audiobookshelf.AudiobookshelfRepository
import com.enve.bookorbit.sync.BookOrbitHistorySessionSync
import com.enve.silo.SiloRepository
import com.enve.app.data.history.HistorySessionStore
import com.enve.app.data.history.AbsCrossProviderHistorySync
import com.enve.app.data.grimmory.GrimmoryReadingSessionUploader
import com.enve.app.data.remote.dto.ReadingSessionRequest
import com.enve.app.data.repository.grimmory.grimmoryServerBookId
import com.enve.core.data.local.PodcastFeedProgress
import com.enve.core.data.local.PodcastFeedProgressStore
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import com.enve.core.data.provider.PlaybackReportEvent
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.di.ApplicationScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.round
import kotlin.math.roundToLong

private const val PERIODIC_FLUSH_INTERVAL_MS = 30_000L
private const val SEEK_SETTLE_MS = 2_000L
private const val SEEK_TOLERANCE_SEC = 2L
private const val MAX_PLAYBACK_SPEED = 4L
private val PLAYBACK_REPORTING_SOURCES = setOf(BookSource.JELLYFIN, BookSource.EMBY, BookSource.PLEX, BookSource.SILO)

internal class ListeningLedger {
    var totalMs = 0L
        private set
    private var syncedMs = 0L

    val unsyncedMs: Long
        get() = totalMs - syncedMs

    fun add(ms: Long) {
        if (ms > 0L) totalMs += ms
    }

    fun acknowledge(ms: Long) {
        syncedMs = (syncedMs + ms).coerceAtMost(totalMs)
    }
}

@Singleton
class PlayerSessionService @Inject constructor(
    private val grimmorySessions: GrimmoryReadingSessionUploader,
    private val audiobookshelfRepository: AudiobookshelfRepository,
    private val bookOrbitHistorySync: BookOrbitHistorySessionSync,
    private val siloRepository: SiloRepository,
    private val history: HistorySessionStore,
    private val crossProviderHistory: AbsCrossProviderHistorySync,
    private val feedProgress: PodcastFeedProgressStore,
    private val providerAdapters: Set<@JvmSuppressWildcards ProviderAdapter>,
    private val progressWrites: com.enve.app.data.sync.AudiobookProgressPushService,
    private val connections: com.enve.core.data.local.ConnectionRegistry,
    @ApplicationScope private val appScope: CoroutineScope,
    private val serverSync: com.enve.core.data.local.ProfileServerSyncStore,
) {
    private val jobLock = Any()
    private val pendingJobs = mutableSetOf<Job>()
    private var closingLocally = false
    private val mutex = Mutex()
    private val remoteMutex = Mutex()
    private var active: ActiveSession? = null
    private var lastResumeRealtimeMs: Long? = null
    private val seekSettleJob = AtomicReference<Job?>(null)

    val hasActiveSession: Boolean
        get() = active != null

    suspend fun start(
        book: Book,
        positionSec: Long,
        durationSec: Long,
        providerSessionId: String? = null,
    ) {
        synchronized(jobLock) { closingLocally = false }
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
                lastFlushAtMs = startedAtMs,
            )
            lastResumeRealtimeMs = null
            current
        }
        sessionToClose?.let { onAppScope { submitSession(it, finished = false) } }
    }

    suspend fun markPlaybackChanged(isPlaying: Boolean, positionSec: Long, durationSec: Long, bookKey: String? = null) {
        var flushNow = false
        var seeked = false
        var report: Pair<ActiveSession, PlaybackReportEvent>? = null
        mutex.withLock {
            val session = active ?: return
            if (bookKey != null && session.bookKey != bookKey) return
            val now = System.currentTimeMillis()
            val wasPlaying = lastResumeRealtimeMs != null
            val position = positionSec.coerceAtLeast(0)
            seeked = session.isJump(position, now, wasPlaying)
            session.lastPositionSec = position
            session.lastTickAtMs = now
            session.durationSec = durationSec.coerceAtLeast(0)
            if (isPlaying) {
                if (lastResumeRealtimeMs == null) {
                    lastResumeRealtimeMs = now
                    report = session to if (session.reportedStart) PlaybackReportEvent.RESUMED else PlaybackReportEvent.STARTED
                    session.reportedStart = true
                } else {
                    accumulateLocked(now)
                }
                if (session.isFlushDue(now)) {
                    session.lastFlushAtMs = now
                    flushNow = true
                }
            } else {
                accumulateLocked(now)
                lastResumeRealtimeMs = null
                flushNow = wasPlaying
                if (wasPlaying) report = session to PlaybackReportEvent.PAUSED
            }
        }
        report?.let { (session, event) -> reportPlayback(session.book, session.reportSessionId, event, positionSec) }
        when {
            flushNow -> flush()
            seeked -> scheduleSeekSettleFlush()
        }
    }

    fun flush() {
        launchSession { flushActive() }
    }

    suspend fun close(positionSec: Long, durationSec: Long, finished: Boolean = false) {
        val session = mutex.withLock {
            val current = active ?: return@withLock null
            current.lastPositionSec = positionSec.coerceAtLeast(0)
            current.durationSec = durationSec.coerceAtLeast(0)
            accumulateLocked()
            lastResumeRealtimeMs = null
            active = null
            current
        } ?: return
        seekSettleJob.getAndSet(null)?.cancel()
        onAppScope { submitSession(session, finished) }
    }

    suspend fun closeLocally(positionSec: Long, durationSec: Long) {
        val jobs = synchronized(jobLock) {
            closingLocally = true
            pendingJobs.toList()
        }
        jobs.forEach { it.cancelAndJoin() }
        val session = mutex.withLock {
            val current = active ?: return@withLock null
            current.lastPositionSec = positionSec.coerceAtLeast(0)
            current.durationSec = durationSec.coerceAtLeast(0)
            accumulateLocked()
            lastResumeRealtimeMs = null
            active = null
            current
        } ?: return
        recordLocalSession(session)
        val snapshot = session.snapshot()
        if (snapshot.isFeedOnly) saveFeedProgress(snapshot, finished = false)
        if (snapshot.book.source == BookSource.AUDIOBOOKSHELF && snapshot.unsyncedListenedMs >= 1_000L) {
            withConnectionScope(snapshot.book) {
                audiobookshelfRepository.recordLocalListening(
                    snapshot.book, snapshot.positionSec, snapshot.durationSec, snapshot.unsyncedListenedMs,
                )
            }
        }
    }

    private fun launchSession(block: suspend () -> Unit): Job? = synchronized(jobLock) {
        if (closingLocally) return@synchronized null
        appScope.launch(start = CoroutineStart.LAZY) {
            try { block() } catch (error: CancellationException) { throw error }
            catch (_: Exception) { android.util.Log.w("PlayerSessionService", "Unable to sync playback session") }
        }.also { job ->
            pendingJobs += job
            job.invokeOnCompletion { synchronized(jobLock) { pendingJobs -= job } }
            job.start()
        }
    }

    private suspend fun onAppScope(block: suspend () -> Unit) {
        launchSession { block() }?.join()
    }

    private fun scheduleSeekSettleFlush() {
        val job = launchSession {
            delay(SEEK_SETTLE_MS)
            flushActive()
        }
        seekSettleJob.getAndSet(job)?.cancel()
    }

    private suspend fun flushActive() {
        remoteMutex.withLock {
            val snapshot = mutex.withLock {
                val session = active ?: return@withLock null
                val now = System.currentTimeMillis()
                accumulateLocked(now)
                session.lastFlushAtMs = now
                session.snapshot()
            } ?: return
            if (!serverSync.accepts(snapshot.startedAtMs)) {
                if (snapshot.isFeedOnly) saveFeedProgress(snapshot, finished = false)
                return@withLock
            }
            when {
                snapshot.isFeedOnly -> saveFeedProgress(snapshot, finished = false)
                snapshot.absSessionId != null -> syncAbsSession(snapshot, close = false)
                snapshot.book.source == BookSource.AUDIOBOOKSHELF -> recordAbsLocalListening(snapshot)
                snapshot.book.source in PLAYBACK_REPORTING_SOURCES ->
                    reportPlayback(snapshot.book, snapshot.reportSessionId, PlaybackReportEvent.PROGRESS, snapshot.positionSec)
            }
        }
    }

    private fun accumulateLocked(now: Long = System.currentTimeMillis()) {
        val resumedAt = lastResumeRealtimeMs ?: return
        if (now > resumedAt) active?.listening?.add(now - resumedAt)
        lastResumeRealtimeMs = now
    }

    private suspend fun recordLocalSession(session: ActiveSession): HistorySession? {
        val listenedMs = session.listening.totalMs
        val endAtMs = System.currentTimeMillis()
        return if (listenedMs >= 1_000L) {
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
    }

    private suspend fun submitSession(session: ActiveSession, finished: Boolean) {
        val listenedMs = session.listening.totalMs
        val endAtMs = System.currentTimeMillis()
        val historySession = recordLocalSession(session)
        if (!serverSync.accepts(session.startedAtMs)) {
            if (session.isFeedOnly) saveFeedProgress(session.snapshot(), finished)
            return
        }
        if (historySession?.source == BookSource.GRIMMORY) {
            try {
                crossProviderHistory.onSession(historySession)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
            }
        }

        if (session.reportedStart) {
            reportPlayback(session.book, session.reportSessionId, PlaybackReportEvent.STOPPED, session.lastPositionSec)
        }

        if (session.book.source == BookSource.SILO) {
            progressWrites.push(session.book, session.lastPositionSec, progress(session.lastPositionSec, session.durationSec) ?: 0f,
                canWrite = { serverSync.accepts(session.startedAtMs) }) { book, position, percentage ->
                withConnection(book) {
                    val result = siloRepository.syncAudiobookProgress(book, position, percentage)
                    if (result.isSuccess && serverSync.accepts(session.startedAtMs)) siloRepository.stopPlaybackSession(book)
                    result
                }
            }
        }

        if (session.absSessionId != null || session.isFeedOnly) {
            remoteMutex.withLock {
                val snapshot = mutex.withLock { session.snapshot() }
                if (session.isFeedOnly) {
                    saveFeedProgress(snapshot, finished)
                } else {
                    syncAbsSession(snapshot, close = true)
                    if (finished && session.book.episodeId != null) markEpisodeFinished(snapshot)
                }
            }
            return
        }

        if (session.book.source == BookSource.AUDIOBOOKSHELF) {
            remoteMutex.withLock { recordAbsLocalListening(mutex.withLock { session.snapshot() }) }
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
                        grimmorySessions.upload(
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

    private suspend fun syncAbsSession(snapshot: SessionSnapshot, close: Boolean) {
        if (!serverSync.isEnabled) return
        val sessionId = snapshot.absSessionId ?: return
        if (!close && snapshot.durationSec <= 0L) return
        val result = progressWrites.push(snapshot.book, snapshot.positionSec, progress(snapshot.positionSec, snapshot.durationSec) ?: 0f,
            canWrite = { serverSync.accepts(snapshot.startedAtMs) }) { book, position, _ ->
            withConnection(book) {
                val duration = book.duration.takeIf { it > 0L } ?: snapshot.durationSec
                if (close) {
                    audiobookshelfRepository.closePlaybackSession(
                        sessionId = sessionId,
                        currentTimeSec = position,
                        timeListenedMs = snapshot.unsyncedListenedMs,
                        durationSec = duration,
                    )
                } else {
                    audiobookshelfRepository.syncPlaybackSession(
                        sessionId = sessionId,
                        currentTimeSec = position,
                        timeListenedMs = snapshot.unsyncedListenedMs,
                        durationSec = duration,
                    )
                }
            }
        }
        if (result.isSuccess) {
            mutex.withLock { snapshot.listening.acknowledge(snapshot.unsyncedListenedMs) }
        } else {
            recordAbsLocalListening(snapshot)
            syncAbsProgressDirectly(snapshot)
        }
    }

    private fun reportPlayback(book: Book, sessionId: String, event: PlaybackReportEvent, positionSec: Long) {
        if (!serverSync.isEnabled || book.source !in PLAYBACK_REPORTING_SOURCES) return
        val adapter = providerAdapters.firstOrNull { it.source == book.source } ?: return
        val requestedAt = System.currentTimeMillis()
        launchSession {
            progressWrites.push(book, positionSec, progress(positionSec, book.duration) ?: book.progress,
                canWrite = { serverSync.accepts(requestedAt) }, acknowledgePending = false, recordOutboundEcho = false) { checkpoint, position, _ ->
                withConnection(checkpoint) { adapter.reportPlayback(checkpoint, event, sessionId, position) }
            }
        }
    }

    private suspend fun recordAbsLocalListening(snapshot: SessionSnapshot) {
        if (!serverSync.isEnabled) return
        val listenedMs = snapshot.unsyncedListenedMs
        if (listenedMs >= 1_000L) {
            withConnectionScope(snapshot.book) {
                audiobookshelfRepository.recordLocalListening(snapshot.book, snapshot.positionSec, snapshot.durationSec, listenedMs)
            }
            mutex.withLock { snapshot.listening.acknowledge(listenedMs) }
        }
        withConnection(snapshot.book) { audiobookshelfRepository.uploadLocalListening() }
    }

    private suspend fun markEpisodeFinished(snapshot: SessionSnapshot) {
        if (!serverSync.isEnabled) return
        val durationSec = snapshot.durationSec.takeIf { it > 0L } ?: snapshot.book.duration
        progressWrites.push(snapshot.book.copy(duration = durationSec), durationSec, 1f,
            canWrite = { serverSync.accepts(snapshot.startedAtMs) }) { book, position, percentage ->
            withConnection(book) { audiobookshelfRepository.syncAudiobookProgress(book, position, percentage) }
        }
    }

    private suspend fun saveFeedProgress(snapshot: SessionSnapshot, finished: Boolean) {
        val durationSec = snapshot.durationSec.takeIf { it > 0L } ?: snapshot.book.duration
        feedProgress.save(
            snapshot.book.uniqueKey,
            PodcastFeedProgress(
                positionSec = if (finished) durationSec else snapshot.positionSec,
                durationSec = durationSec,
                isFinished = finished,
                updatedAtMs = System.currentTimeMillis(),
            ),
        )
    }

    private suspend fun syncAbsProgressDirectly(snapshot: SessionSnapshot) {
        if (!serverSync.isEnabled) return
        if (snapshot.durationSec <= 0L) return
        val progress = (snapshot.positionSec.toFloat() / snapshot.durationSec.toFloat()).coerceIn(0f, 1f)
        progressWrites.push(snapshot.book, snapshot.positionSec, progress,
            canWrite = { serverSync.accepts(snapshot.startedAtMs) }) { book, position, percentage ->
            withConnection(book) { audiobookshelfRepository.syncAudiobookProgress(book, position, percentage) }
        }
    }

    private suspend fun <T> withConnectionScope(book: Book, block: suspend () -> T): T {
        val connectionId = book.connectionId ?: return block()
        return withContext(ConnectionScope.asContextElement(connectionId)) { block() }
    }

    private suspend fun <T> withConnection(book: Book, block: suspend () -> T): T = withConnectionScope(book) {
        val connectionId = book.connectionId
        if (connectionId != null) {
            check(connections.connections.first().any { it.id == connectionId && it.source == book.source && it.enabled }) {
                "Requested provider connection is unavailable"
            }
        }
        block()
    }

    private data class ActiveSession(
        val book: Book,
        val bookKey: String,
        val startedAtMs: Long,
        var durationSec: Long,
        val startPositionSec: Long,
        var lastPositionSec: Long,
        var absSessionId: String? = null,
        val reportSessionId: String = UUID.randomUUID().toString(),
        var reportedStart: Boolean = false,
        var lastFlushAtMs: Long = startedAtMs,
        var lastTickAtMs: Long? = null,
        val listening: ListeningLedger = ListeningLedger(),
    ) {
        val isFeedOnly: Boolean
            get() = book.podcastEnclosureUrl != null

        fun isFlushDue(nowMs: Long): Boolean =
            (absSessionId != null || isFeedOnly || book.source == BookSource.AUDIOBOOKSHELF || book.source in PLAYBACK_REPORTING_SOURCES) &&
                durationSec > 0L &&
                nowMs - lastFlushAtMs >= PERIODIC_FLUSH_INTERVAL_MS

        fun isJump(positionSec: Long, nowMs: Long, wasPlaying: Boolean): Boolean {
            val previousTickAt = lastTickAtMs ?: return false
            val elapsedSec = (nowMs - previousTickAt + 999L) / 1_000L
            val maxAdvanceSec = if (wasPlaying) elapsedSec * MAX_PLAYBACK_SPEED else 0L
            return positionSec < lastPositionSec - SEEK_TOLERANCE_SEC ||
                positionSec > lastPositionSec + maxAdvanceSec + SEEK_TOLERANCE_SEC
        }

        fun snapshot(): SessionSnapshot = SessionSnapshot(
            book = book,
            startedAtMs = startedAtMs,
            absSessionId = absSessionId,
            reportSessionId = reportSessionId,
            isFeedOnly = isFeedOnly,
            positionSec = lastPositionSec,
            durationSec = durationSec,
            unsyncedListenedMs = listening.unsyncedMs,
            listening = listening,
        )
    }

    private class SessionSnapshot(
        val book: Book,
        val startedAtMs: Long,
        val absSessionId: String?,
        val reportSessionId: String,
        val isFeedOnly: Boolean,
        val positionSec: Long,
        val durationSec: Long,
        val unsyncedListenedMs: Long,
        val listening: ListeningLedger,
    )
}
