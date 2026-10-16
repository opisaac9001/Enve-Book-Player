package com.enve.hearth

import com.enve.core.data.local.HearthDismissedShelfStore
import com.enve.core.data.local.LastOpenedBookStore
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.engine.library.LibraryFacade
import com.enve.engine.playback.PlaybackFacade
import javax.inject.Inject

private const val MEANINGFUL_LISTENED_SECONDS = 120L
private const val MEANINGFUL_READ_FRACTION = 0.01f

fun Book.needsUnreadConfirmation(): Boolean {
    if (isFinished) return true
    if (mediaType == AppMediaType.EBOOK) {
        return maxOf(readProgress, epubProgress ?: 0f) > MEANINGFUL_READ_FRACTION || currentTime > MEANINGFUL_LISTENED_SECONDS
    }
    val listened = if (currentTime > 0L) currentTime else (duration * readProgress.coerceIn(0f, 1f)).toLong()
    return listened > MEANINGFUL_LISTENED_SECONDS
}

class MarkUnreadAction @Inject constructor(
    private val library: LibraryFacade,
    private val playback: PlaybackFacade,
    private val lastOpened: LastOpenedBookStore,
    private val dismissedShelves: HearthDismissedShelfStore,
) {
    suspend operator fun invoke(book: Book) {
        if (playback.nowPlaying.value?.bookKey == book.uniqueKey) playback.stop()
        lastOpened.forget(book.uniqueKey)
        dismissedShelves.restore(book.uniqueKey)
        library.resetProgress(book)
    }
}
