package com.enve.app.playback

import com.enve.app.data.sync.SyncCoordinator
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.PendingProgressPushDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.util.resolveAudiobookPositionSeconds
import com.enve.core.data.sync.AudiobookCheckpointOrder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject
import javax.inject.Singleton

data class PlaybackProgressConflict(
    val localPercentage: Float,
    val localUpdatedAt: Long?,
    val remotePercentage: Float,
    val remoteUpdatedAt: Long?,
    val remoteSource: String,
)

enum class PlaybackProgressConflictChoice { LOCAL, REMOTE, LATER }

@Singleton
class PlaybackOpenProgressResolver internal constructor(
    private val bookCache: BookCacheDao,
    private val pending: PendingProgressPushDao,
    private val checkpointOrder: AudiobookCheckpointOrder,
    private val pullProgress: suspend (Book, Float, Long?) -> SyncCoordinator.OpenSyncResult,
    private val syncIsEnabled: () -> Boolean,
    private val syncAccepts: (Long) -> Boolean,
    private val recordChoice: (Book, String, Boolean) -> Unit,
) {
    @Inject constructor(
        syncCoordinator: SyncCoordinator,
        bookCache: BookCacheDao,
        pending: PendingProgressPushDao,
        serverSync: com.enve.core.data.local.ProfileServerSyncStore,
        checkpointOrder: AudiobookCheckpointOrder,
    ) : this(
        bookCache, pending, checkpointOrder,
        { book, percentage, updatedAt ->
            syncCoordinator.pullOnOpenResolved(book, percentage, updatedAt)
        },
        { serverSync.isEnabled },
        serverSync::accepts,
        { book, source, remote -> syncCoordinator.recordConflictResolution(book, source, remote) },
    )

    private data class SubmittedChoice(val choice: PlaybackProgressConflictChoice, val sequence: Long)
    private val _pendingConflict = MutableStateFlow<PlaybackProgressConflict?>(null)
    val pendingConflict: StateFlow<PlaybackProgressConflict?> = _pendingConflict.asStateFlow()

    private val promptMutex = Mutex()

    @Volatile
    private var pendingChoice: CompletableDeferred<SubmittedChoice>? = null

    @Volatile
    private var heldBookKey: String? = null

    suspend fun resolveStartSeconds(book: Book, promptForConflict: Boolean = true): Long {
        if (heldBookKey == book.uniqueKey) heldBookKey = null
        val syncStartedAt = System.currentTimeMillis()
        val (checkpoint, hasPending) = readLocalCheckpoint(book)
        val localBook = checkpoint?.toBook()?.forAudioPlayback()?.copy(
            duration = book.duration.takeIf { it > 0L } ?: checkpoint.duration,
        ) ?: book
        val localStart = audioLocalStartSeconds(localBook)
        if (hasPending) return localStart
        val automaticSequence = checkpointOrder.newSequence()
        val result = try {
            pullProgress(localBook, audioLocalPercentage(localBook), audioLocalUpdatedAt(localBook))
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return latestLocalStart(book)
        }

        if (!syncAccepts(syncStartedAt)) return latestLocalStart(book)
        if (bookCache.getByCacheKey(book.uniqueKey) != checkpoint) {
            return latestLocalStart(book)
        }
        return when (result) {
            is SyncCoordinator.OpenSyncResult.Apply -> {
                val remote = result.snapshot
                if (!result.useRemote || remote == null) {
                    localStart
                } else {
                    val start = remoteStartSeconds(remote.positionMs, remote.percentage, book.duration)
                    if (mirrorPlaybackCheckpoint(checkpointOrder, book.uniqueKey, checkpoint, automaticSequence,
                            isEnabled = { syncIsEnabled() }) {
                            writeRemoteCheckpoint(it, remote.percentage, start)
                        }) start else latestLocalStart(book)
                }
            }
            is SyncCoordinator.OpenSyncResult.Conflict -> {
                val submitted = if (!promptForConflict) SubmittedChoice(PlaybackProgressConflictChoice.LATER, 0L) else awaitChoice(
                    PlaybackProgressConflict(
                        localPercentage = result.local.percentage,
                        localUpdatedAt = result.local.updatedAt,
                        remotePercentage = result.remote.percentage,
                        remoteUpdatedAt = result.remote.updatedAt,
                        remoteSource = result.remoteSource,
                    ),
                )
                if (!syncAccepts(syncStartedAt)) return latestLocalStart(book)
                when (submitted.choice) {
                    PlaybackProgressConflictChoice.LOCAL -> {
                        recordChoice(book, result.remoteSource, false)
                        latestLocalStart(book)
                    }
                    PlaybackProgressConflictChoice.LATER -> {
                        heldBookKey = book.uniqueKey
                        latestLocalStart(book)
                    }
                    PlaybackProgressConflictChoice.REMOTE -> {
                        val choiceSequence = submitted.sequence
                        val chosenCheckpoint = bookCache.getByCacheKey(book.uniqueKey)
                        val start = remoteStartSeconds(result.remote.positionMs, result.remote.percentage, book.duration)
                        val mirrored = mirrorPlaybackCheckpoint(checkpointOrder, book.uniqueKey, chosenCheckpoint, choiceSequence,
                            explicitChoice = true, isEnabled = { syncIsEnabled() }) {
                            writeRemoteCheckpoint(it, result.remote.percentage, start)
                        }
                        if (mirrored) {
                            recordChoice(book, result.remoteSource, true)
                            start
                        } else latestLocalStart(book)
                    }
                }
            }
        }
    }

    fun shouldHoldPush(book: Book): Boolean = heldBookKey == book.uniqueKey

    fun resolveConflict(choice: PlaybackProgressConflictChoice) {
        val waiting = pendingChoice ?: return
        waiting.complete(SubmittedChoice(choice, checkpointOrder.newSequence()))
    }

    private suspend fun awaitChoice(conflict: PlaybackProgressConflict): SubmittedChoice =
        promptMutex.withLock {
            if (_pendingConflict.subscriptionCount.value == 0) return@withLock SubmittedChoice(PlaybackProgressConflictChoice.LATER, 0L)
            val deferred = CompletableDeferred<SubmittedChoice>()
            pendingChoice = deferred
            _pendingConflict.value = conflict
            try {
                withTimeoutOrNull(CONFLICT_PROMPT_TIMEOUT_MS) { deferred.await() }
                    ?: SubmittedChoice(PlaybackProgressConflictChoice.LATER, 0L)
            } finally {
                pendingChoice = null
                _pendingConflict.value = null
            }
        }

    private suspend fun readLocalCheckpoint(book: Book): Pair<CachedBook?, Boolean> = checkpointOrder.serialized {
        val first = bookCache.getByCacheKey(book.uniqueKey)
        val hasPending = pending.get(book.id, book.source.name, book.connectionId.orEmpty()) != null
        val checkpoint = if (hasPending) bookCache.getByCacheKey(book.uniqueKey) else first
        checkpoint to hasPending
    }

    private suspend fun latestLocalStart(book: Book): Long =
        audioLocalStartSeconds(readLocalCheckpoint(book).first?.toBook()?.forAudioPlayback() ?: book)

    private suspend fun writeRemoteCheckpoint(
        checkpoint: CachedBook,
        percentage: Float,
        startSeconds: Long,
    ): Boolean = bookCache.updateAudiobookProgressIfUnchanged(
        expected = checkpoint,
        progress = percentage.coerceIn(0f, 1f),
        currentTimeSec = startSeconds,
        nowMs = System.currentTimeMillis(),
    ) > 0

    private companion object {
        const val CONFLICT_PROMPT_TIMEOUT_MS = 30_000L
    }
}

internal suspend fun mirrorPlaybackCheckpoint(
    order: AudiobookCheckpointOrder,
    key: String,
    checkpoint: CachedBook?,
    sequence: Long,
    explicitChoice: Boolean = false,
    isEnabled: () -> Boolean = { true },
    write: suspend (CachedBook) -> Boolean,
): Boolean = order.serialized { state ->
    if (!isEnabled() || state.isSuperseded(key, sequence) || state.hasCaptureAfter(key, sequence) ||
        (!explicitChoice && state.hasPendingCapture(key))
    ) return@serialized false
    if (checkpoint == null) return@serialized true
    val updated = write(checkpoint)
    if (updated) state.recordApplied(key, sequence)
    updated
}

internal fun remoteStartSeconds(positionMs: Long?, percentage: Float, durationSeconds: Long): Long =
    resolveAudiobookPositionSeconds(
        positionMs = positionMs,
        fraction = percentage,
        durationSeconds = durationSeconds,
    )

internal fun entityPercentageIsCrossFormat(book: Book): Boolean =
    book.source == BookSource.GRIMMORY &&
        book.currentTime <= 0L &&
        (book.hasEbook || book.epubLocator != null)

internal fun Book.forAudioPlayback(): Book =
    if (mediaType == AppMediaType.EBOOK) copy(mediaType = AppMediaType.AUDIOBOOK, hasEbook = true, hasAudio = true) else this

internal fun audioLocalPercentage(book: Book): Float =
    if (entityPercentageIsCrossFormat(book)) 0f else book.progress

internal fun audioLocalUpdatedAt(book: Book): Long? =
    book.lastReadTime.takeIf { it > 0L && !entityPercentageIsCrossFormat(book) }

internal fun audioLocalStartSeconds(book: Book): Long = when {
    book.currentTime > 0L -> book.currentTime.coerceAtMost(book.duration.takeIf { it > 0L } ?: Long.MAX_VALUE)
    entityPercentageIsCrossFormat(book) -> 0L
    book.duration > 0L -> (book.duration * book.progress.coerceIn(0f, 1f)).toLong()
    else -> 0L
}
