package com.enve.engine.playback

import com.enve.core.data.model.Book
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

data class PlaybackTransport(
    val hasMedia: Boolean,
    val isPlaying: Boolean,
    val positionMs: Long,
    val durationMs: Long,
    val speed: Float,
    val bookId: String?,
) {
    val progress: Float get() = if (durationMs > 0L) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f

    companion object {
        val Empty = PlaybackTransport(false, false, 0L, 0L, 1f, null)
    }
}

data class NowPlaying(
    val bookId: String,
    val bookKey: String,
    val title: String,
    val author: String?,
    val coverUrl: String?,
)

enum class PlaybackQueueOrigin {
    MANUAL,
    PLAY_ALL,
    PODCAST_AUTO,
}

data class PlaybackQueueItem(
    val book: Book,
    val origin: PlaybackQueueOrigin,
    val groupKey: String? = null,
)

interface PlaybackFacade {
    val transport: StateFlow<PlaybackTransport>
    val nowPlaying: StateFlow<NowPlaying?>
    val queue: StateFlow<List<PlaybackQueueItem>>

    val errors: SharedFlow<String>

    fun open(book: Book)
    fun open(book: Book, positionMs: Long)

    fun playAll(books: List<Book>, groupKey: String? = null)
    fun addNext(book: Book)
    fun addLast(book: Book)
    fun addLast(books: List<Book>)
    fun playQueued(bookKey: String)
    fun removeQueued(bookKey: String)
    fun moveQueued(bookKey: String, delta: Int)
    fun clearQueue()

    fun togglePlayPause()
    fun seekTo(positionMs: Long)
    fun skipForward()
    fun skipBackward()
    fun setSpeed(speed: Float)
}
