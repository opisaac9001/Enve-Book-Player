package com.enve.app.listeningposition

import androidx.room.withTransaction
import com.enve.app.data.local.ReaderDatabase
import com.enve.app.data.repository.AggregatorRepository
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.local.PendingProgressPushDao
import com.enve.core.data.local.ProfileServerSyncStore
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.listeningposition.SharedReadingLocation
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.sync.AudiobookCheckpointOrder
import com.enve.core.data.sync.AudiobookProgressWriteCoordinator
import com.enve.core.data.sync.SyncCapabilityFlag
import com.enve.app.data.sync.RemoteProgressWriteKey
import com.enve.app.data.sync.RemoteRewindTracker
import com.enve.engine.listeningposition.ListeningPositionServerStatus
import com.enve.engine.playback.PlaybackFacade
import javax.inject.Inject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.abs

class LiveListeningPositionProgressTarget @Inject constructor(
    private val database: ReaderDatabase,
    private val cache: BookCacheDao,
    private val pending: PendingProgressPushDao,
    private val sync: ProfileServerSyncStore,
    private val repository: AggregatorRepository,
    private val playback: PlaybackFacade,
    private val writers: AudiobookProgressWriteCoordinator,
    private val checkpoints: AudiobookCheckpointOrder,
    private val adapters: Set<@JvmSuppressWildcards ProviderAdapter>,
    private val rewinds: RemoteRewindTracker,
) : ListeningPositionProgressTarget {
    override suspend fun <T> ordered(book: Book, action: suspend () -> T): T =
        withContext(Dispatchers.IO) { writers.ordered(book.source, book.connectionId, action) }

    override suspend fun reload(book: Book): Book = cache.getByCacheKey(book.uniqueKey)?.toBook()
        ?.takeIf { it.source == book.source && it.connectionId == book.connectionId }
        ?: throw IllegalArgumentException("This copy is no longer in your library.")

    override suspend fun seekIfLoaded(book: Book, positionMilliseconds: Long) {
        withContext(Dispatchers.Main.immediate) {
            if (playback.nowPlaying.value?.bookKey != book.uniqueKey) return@withContext
            playback.seekTo(positionMilliseconds)
            val sought = withTimeoutOrNull(5000) {
                playback.transport.first {
                    playback.nowPlaying.value?.bookKey != book.uniqueKey || abs(it.positionMs - positionMilliseconds) <= 250
                }
                true
            }
            check(sought == true) { "Couldn't seek the loaded book. Try again when playback is ready." }
        }
    }

    override suspend fun save(book: Book, positionMilliseconds: Long): Book {
        val token = checkpoints.capture(book.uniqueKey)
        return checkpoints.serialized { state ->
            database.withTransaction {
                val position = positionMilliseconds / 1000L
                val progress = if (book.duration > 0) (positionMilliseconds / 1000.0 / book.duration).toFloat().coerceIn(0f, 1f) else 0f
                val now = System.currentTimeMillis()
                val finished = progress >= 0.99f
                val status = if (!finished && book.serverReadStatus in setOf("READ", "COMPLETED", "FINISHED")) "RE_READING" else book.serverReadStatus
                check(cache.updateAudiobookCommand(book.uniqueKey, progress, position, finished, book.hideFromContinue, status, now) == 1) { "This copy is no longer in your library." }
                val updated = reload(book)
                if (route(updated) == ListeningPositionServerStatus.QUEUED) {
                    val old = pending.get(book.id, book.source.name, book.connectionId.orEmpty())
                    pending.upsert(PendingProgressPush(book.id, book.source.name, book.connectionId.orEmpty(), "AUDIOBOOK",
                        progress, updated.isFinished, maxOf(now, (old?.createdAt ?: 0L) + 1)))
                }
                state.recordApplied(book.uniqueKey, token)
                updated
            }
        }
    }

    override suspend fun saveReading(book: Book, location: SharedReadingLocation): Book = database.withTransaction {
        val progress = location.progressionFor(book).coerceIn(0f, 1f)
        val finished = progress >= 0.99f
        val status = if (!finished && book.serverReadStatus in setOf("READ", "COMPLETED", "FINISHED")) "RE_READING" else book.serverReadStatus
        val now = System.currentTimeMillis()
        check(cache.updateReadingCommand(book.uniqueKey, progress, location.locatorFor(book), finished, status, now) == 1) { "This copy is no longer in your library." }
        val updated = reload(book)
        if (route(updated) == ListeningPositionServerStatus.QUEUED) {
            val old = pending.get(book.id, book.source.name, book.connectionId.orEmpty())
            pending.upsert(PendingProgressPush(book.id, book.source.name, book.connectionId.orEmpty(), AppMediaType.EBOOK.name,
                progress, finished, maxOf(now, (old?.createdAt ?: 0L) + 1)))
        }
        updated
    }

    override suspend fun push(book: Book): ListeningPositionServerStatus {
        val route = route(book)
        if (route != ListeningPositionServerStatus.QUEUED) return route
        val queued = pending.get(book.id, book.source.name, book.connectionId.orEmpty())
        val before = cache.getByCacheKey(book.uniqueKey)
        try {
            if (book.mediaType == AppMediaType.EBOOK) {
                val location = SharedReadingLocation.from(book)
                repository.syncEbookProgress(book.id, book.source, book.epubProgress ?: book.readProgress,
                    book.epubLocator, location.page, book.pageCount, book.connectionId).getOrThrow()
                val after = cache.getByCacheKey(book.uniqueKey)
                val unchanged = before != null && after?.copy(lastReadTime = before.lastReadTime, inProgress = before.inProgress) == before
                if (queued != null && unchanged && sync.accepts(queued.createdAt)) {
                    rewinds.recordOutboundWrite(RemoteProgressWriteKey.of(book), book.epubProgress ?: book.readProgress, null, book.epubLocator)
                    pending.deleteIfUnchanged(book.id, book.source.name, book.connectionId.orEmpty(), queued.createdAt, queued.percentage)
                }
            } else repository.syncAudiobookProgress(book, book.currentTime, book.readProgress).getOrThrow()
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            return ListeningPositionServerStatus.QUEUED
        }
        return if (pending.get(book.id, book.source.name, book.connectionId.orEmpty()) == null) ListeningPositionServerStatus.SAVED
            else ListeningPositionServerStatus.QUEUED
    }

    private fun route(book: Book): ListeningPositionServerStatus = when {
        !sync.isEnabled -> ListeningPositionServerStatus.SYNC_DISABLED
        book.source == BookSource.LOCAL || adapters.none { it.source == book.source && it.syncCapability.supports(SyncCapabilityFlag.PUSH_PROGRESS) } -> ListeningPositionServerStatus.NO_SERVER
        book.mediaType != AppMediaType.EBOOK && book.duration <= 0 -> ListeningPositionServerStatus.UNKNOWN_LENGTH
        else -> ListeningPositionServerStatus.QUEUED
    }
}
