package com.enve.hearth.journal

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import org.junit.Assert.assertEquals
import org.junit.Test

class CompletionCenterPolicyTest {
    @Test
    fun almostFinishedUsesCanonicalProgressAndExcludesFinishedBooksAndPodcasts() {
        val books = listOf(
            book("audio-80", progress = 0.80f, lastReadTime = 30L),
            book("audio-90", duration = 100L, currentTime = 90L, lastReadTime = 20L),
            book("ebook-85", mediaType = AppMediaType.EBOOK, epubProgress = 0.85f, lastReadTime = 10L),
            book("too-early", progress = 0.74f),
            book("complete-progress", progress = 0.99f),
            book("finished", progress = 0.90f, finished = true),
            book("podcast", progress = 0.90f, mediaType = AppMediaType.PODCAST),
        )

        assertEquals(
            listOf("audio-90", "ebook-85", "audio-80"),
            CompletionCenterPolicy.almostFinished(books).map(Book::id),
        )
    }

    @Test
    fun recentlyFinishedUsesLastReadTimeAndExcludesPodcasts() {
        val books = listOf(
            book("older", finished = true, lastReadTime = 10L),
            book("newer", finished = true, lastReadTime = 30L),
            book("unfinished", lastReadTime = 40L),
            book("podcast", finished = true, mediaType = AppMediaType.PODCAST, lastReadTime = 50L),
        )

        assertEquals(
            listOf("newer", "older"),
            CompletionCenterPolicy.recentlyFinished(books).map(Book::id),
        )
    }

    private fun book(
        id: String,
        progress: Float = 0f,
        duration: Long = 0L,
        currentTime: Long = 0L,
        epubProgress: Float? = null,
        finished: Boolean = false,
        mediaType: AppMediaType = AppMediaType.AUDIOBOOK,
        lastReadTime: Long = 0L,
    ) = Book(
        id = id,
        title = id,
        readProgress = progress,
        duration = duration,
        currentTime = currentTime,
        epubProgress = epubProgress,
        isFinished = finished,
        mediaType = mediaType,
        lastReadTime = lastReadTime,
    )
}
