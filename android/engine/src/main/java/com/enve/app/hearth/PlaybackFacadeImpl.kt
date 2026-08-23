package com.enve.app.hearth

import android.util.Log
import com.enve.app.playback.AudioPlaybackManager
import com.enve.app.playback.AutoMediaBrowserHelper
import com.enve.app.playback.PlaybackQueueCoordinator
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.Book
import com.enve.engine.playback.NowPlaying
import com.enve.engine.playback.PlaybackFacade
import com.enve.engine.playback.PlaybackQueueItem
import com.enve.engine.playback.PlaybackTransport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PlaybackFacadeImpl @Inject constructor(
    private val audioManager: AudioPlaybackManager,
    private val bookCache: BookCacheDao,
    private val queueCoordinator: PlaybackQueueCoordinator,
    private val preferences: PreferencesManager,
) : PlaybackFacade {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val skipForwardSeconds = preferences.skipForwardSeconds
        .stateIn(scope, SharingStarted.Eagerly, 30)
    private val skipBackwardSeconds = preferences.skipBackwardSeconds
        .stateIn(scope, SharingStarted.Eagerly, 30)

    private val _errors = MutableSharedFlow<String>(extraBufferCapacity = 4)
    override val errors: SharedFlow<String> = _errors.asSharedFlow()

    init {
        audioManager.connect()
    }

    override val queue: StateFlow<List<PlaybackQueueItem>> = queueCoordinator.queue

    override fun open(book: Book) {
        openInternal(book, seekAfterStartMs = null)
    }

    override fun open(book: Book, positionMs: Long) {
        openInternal(book, seekAfterStartMs = positionMs.coerceAtLeast(0L))
    }

    private fun openInternal(book: Book, seekAfterStartMs: Long?) {
        launchPlayback("Couldn't start \"${book.title}\". Check the source connection.") {
            queueCoordinator.open(book, seekAfterStartMs)
        }
    }

    override fun playAll(books: List<Book>, groupKey: String?) {
        launchPlayback("Couldn't start this group. Check the source connection.") {
            queueCoordinator.playAll(books, groupKey)
        }
    }

    override fun addNext(book: Book) {
        launchPlayback("Couldn't add \"${book.title}\" to Up Next.") {
            queueCoordinator.addNext(book)
        }
    }

    override fun addLast(book: Book) {
        launchPlayback("Couldn't add \"${book.title}\" to the queue.") {
            queueCoordinator.addLast(book)
        }
    }

    override fun addLast(books: List<Book>) {
        launchPlayback("Couldn't add the selected books to Up Next.") {
            queueCoordinator.addLast(books)
        }
    }

    override fun playQueued(bookKey: String) {
        launchPlayback("Couldn't start that queued book.") {
            queueCoordinator.playQueued(bookKey)
        }
    }

    override fun removeQueued(bookKey: String) {
        scope.launch { queueCoordinator.remove(bookKey) }
    }

    override fun moveQueued(bookKey: String, delta: Int) {
        scope.launch { queueCoordinator.move(bookKey, delta) }
    }

    override fun clearQueue() {
        scope.launch { queueCoordinator.clear() }
    }

    private fun launchPlayback(errorMessage: String, action: suspend () -> Boolean) {
        scope.launch {
            val succeeded = try {
                action()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e("PlaybackFacade", errorMessage, e)
                false
            }
            if (!succeeded) _errors.emit(errorMessage)
        }
    }

    override val transport: StateFlow<PlaybackTransport> =
        combine(audioManager.state, audioManager.currentBookIdFlow) { s, bookId ->
            PlaybackTransport(
                hasMedia = bookId != null || s.durationMs > 0L,
                isPlaying = s.isPlaying,
                positionMs = s.currentPositionMs,
                durationMs = s.durationMs,
                speed = s.playbackSpeed,
                bookId = bookId,
            )
        }.stateIn(scope, SharingStarted.WhileSubscribed(5000), PlaybackTransport.Empty)

    @OptIn(ExperimentalCoroutinesApi::class)
    override val nowPlaying: StateFlow<NowPlaying?> =
        combine(audioManager.currentBookIdFlow, audioManager.state) { bookId, state ->
            bookId to state.mediaId?.let(AutoMediaBrowserHelper::cacheKeyFrom)
        }.distinctUntilChanged()
            .mapLatest { (id, key) ->
                if (id == null) return@mapLatest null
                val exact = key?.let { bookCache.getByCacheKey(it) }?.takeIf { it.id == id }
                (exact ?: bookCache.getById(id))?.let { cached ->
                    NowPlaying(
                        bookId = cached.id,
                        bookKey = cached.cacheKey,
                        title = cached.title,
                        author = cached.author,
                        coverUrl = cached.coverUrl,
                    )
                }
            }
            .stateIn(scope, SharingStarted.WhileSubscribed(5000), null)

    override fun togglePlayPause() = audioManager.togglePlayPause()
    override fun seekTo(positionMs: Long) = audioManager.seekTo(positionMs)
    override fun skipForward() = audioManager.skipForward(skipForwardSeconds.value * 1000L)
    override fun skipBackward() = audioManager.skipBackward(skipBackwardSeconds.value * 1000L)

    override fun setSpeed(speed: Float) {
        audioManager.setPlaybackSpeed(speed)
        scope.launch { preferences.setPlaybackSpeed(speed) }
    }
}
