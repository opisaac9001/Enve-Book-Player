package com.enve.app.playback

import com.enve.app.data.sync.SyncCoordinator
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.util.resolveAudiobookPositionSeconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
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
class PlaybackOpenProgressResolver @Inject constructor(
    private val syncCoordinator: SyncCoordinator,
    private val bookCache: BookCacheDao,
) {
    private val _pendingConflict = MutableStateFlow<PlaybackProgressConflict?>(null)
    val pendingConflict: StateFlow<PlaybackProgressConflict?> = _pendingConflict.asStateFlow()

    private val promptMutex = Mutex()

    @Volatile
    private var pendingChoice: CompletableDeferred<PlaybackProgressConflictChoice>? = null

    @Volatile
    private var heldBookKey: String? = null

    suspend fun resolveStartSeconds(book: Book): Long {
        if (heldBookKey == book.uniqueKey) heldBookKey = null
        val localStart = audioLocalStartSeconds(book)
        val result = try {
            syncCoordinator.pullOnOpenResolved(
                book = book,
                localPercentage = audioLocalPercentage(book),
                localUpdatedAt = audioLocalUpdatedAt(book),
            )
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return localStart
        }

        return when (result) {
            is SyncCoordinator.OpenSyncResult.Apply -> {
                val remote = result.snapshot
                if (!result.useRemote || remote == null) {
                    localStart
                } else {
                    val start = remoteStartSeconds(remote.positionMs, remote.percentage, book.duration)
                    mirrorRemote(book, remote.percentage, remote.locatorJson, start)
                    start
                }
            }
            is SyncCoordinator.OpenSyncResult.Conflict -> {
                val choice = awaitChoice(
                    PlaybackProgressConflict(
                        localPercentage = result.local.percentage,
                        localUpdatedAt = result.local.updatedAt,
                        remotePercentage = result.remote.percentage,
                        remoteUpdatedAt = result.remote.updatedAt,
                        remoteSource = result.remoteSource,
                    ),
                )
                when (choice) {
                    PlaybackProgressConflictChoice.LOCAL -> {
                        syncCoordinator.recordConflictResolution(book, result.remoteSource, acceptedRemote = false)
                        localStart
                    }
                    PlaybackProgressConflictChoice.LATER -> {
                        heldBookKey = book.uniqueKey
                        localStart
                    }
                    PlaybackProgressConflictChoice.REMOTE -> {
                        syncCoordinator.recordConflictResolution(book, result.remoteSource, acceptedRemote = true)
                        val start = remoteStartSeconds(result.remote.positionMs, result.remote.percentage, book.duration)
                        mirrorRemote(book, result.remote.percentage, result.remote.locatorJson, start)
                        start
                    }
                }
            }
        }
    }

    fun shouldHoldPush(book: Book): Boolean = heldBookKey == book.uniqueKey

    fun resolveConflict(choice: PlaybackProgressConflictChoice) {
        pendingChoice?.complete(choice)
    }

    private suspend fun awaitChoice(conflict: PlaybackProgressConflict): PlaybackProgressConflictChoice =
        promptMutex.withLock {
            if (_pendingConflict.subscriptionCount.value == 0) return@withLock PlaybackProgressConflictChoice.LATER
            val deferred = CompletableDeferred<PlaybackProgressConflictChoice>()
            pendingChoice = deferred
            _pendingConflict.value = conflict
            try {
                withTimeoutOrNull(CONFLICT_PROMPT_TIMEOUT_MS) { deferred.await() }
                    ?: PlaybackProgressConflictChoice.LATER
            } finally {
                pendingChoice = null
                _pendingConflict.value = null
            }
        }

    private suspend fun mirrorRemote(
        book: Book,
        percentage: Float,
        locatorJson: String?,
        startSeconds: Long,
    ) = withContext(Dispatchers.IO) {
        val rows = bookCache.updateUnifiedProgress(
            bookId = book.id,
            connectionId = book.connectionId,
            progress = percentage.coerceIn(0f, 1f),
            currentTimeSec = startSeconds,
            locatorJson = locatorJson,
            nowMs = System.currentTimeMillis(),
        )
        if (rows == 0) {
            bookCache.updateUnifiedProgressById(
                bookId = book.id,
                progress = percentage.coerceIn(0f, 1f),
                currentTimeSec = startSeconds,
                locatorJson = locatorJson,
                nowMs = System.currentTimeMillis(),
            )
        }
    }

    private companion object {
        const val CONFLICT_PROMPT_TIMEOUT_MS = 30_000L
    }
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
