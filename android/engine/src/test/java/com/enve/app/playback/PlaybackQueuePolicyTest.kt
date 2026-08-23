package com.enve.app.playback

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackQueuePolicyTest {
    @Test
    fun playAllUsesOnlyUnfinishedAudioWhenAnyRemain() {
        val books = listOf(
            book("finished", finished = true),
            book("next"),
            book("ebook", mediaType = AppMediaType.EBOOK),
            book("later", progress = 0.4f),
        )

        assertEquals(listOf("next", "later"), PlaybackQueuePolicy.playAllCandidates(books).map(Book::id))
    }

    @Test
    fun playAllIncludesCompletedAudioWhenEverythingIsFinished() {
        val books = listOf(book("one", finished = true), book("two", progress = 1f))

        assertEquals(listOf("one", "two"), PlaybackQueuePolicy.playAllCandidates(books).map(Book::id))
    }

    @Test
    fun playAllKeepsFirstOccurrenceOfDuplicateBook() {
        val books = listOf(book("one"), book("two"), book("one"))

        assertEquals(listOf("one", "two"), PlaybackQueuePolicy.playAllCandidates(books).map(Book::id))
    }

    @Test
    fun manualCandidatesKeepPlayableBooksInSelectionOrder() {
        val books = listOf(
            book("one"),
            book("ebook", mediaType = AppMediaType.EBOOK),
            book("two"),
            book("one"),
        )

        assertEquals(listOf("one", "two"), PlaybackQueuePolicy.manualCandidates(books).map(Book::id))
    }

    @Test
    fun seriesAutoAdvanceUsesTheNearestLaterUnfinishedAudiobook() {
        val current = book("current", seriesNumber = "2")
        val books = listOf(
            book("later", seriesNumber = "4"),
            book("finished", finished = true, seriesNumber = "2.5"),
            book("next", seriesNumber = "3"),
            book("earlier", seriesNumber = "1"),
        )

        assertEquals(
            listOf("next", "later"),
            PlaybackQueuePolicy.seriesAutoAdvanceCandidates(current, books).map(Book::id),
        )
    }

    @Test
    fun seriesAutoAdvanceStaysWithinTheOriginatingLibraryAndConnection() {
        val current = book("current", seriesNumber = "1")
        val books = listOf(
            book("next", seriesNumber = "2"),
            book("other-library", seriesNumber = "2", libraryId = "other"),
            book("other-connection", seriesNumber = "2", connectionId = "other"),
            book("podcast", seriesNumber = "2", mediaType = AppMediaType.PODCAST),
        )

        assertEquals(
            listOf("next"),
            PlaybackQueuePolicy.seriesAutoAdvanceCandidates(current, books).map(Book::id),
        )
    }

    @Test
    fun seriesAutoAdvanceRequiresANumericCurrentSequence() {
        val current = book("current", seriesNumber = null)

        assertEquals(
            emptyList<Book>(),
            PlaybackQueuePolicy.seriesAutoAdvanceCandidates(
                current,
                listOf(book("next", seriesNumber = "2")),
            ),
        )
    }

    private fun book(
        id: String,
        finished: Boolean = false,
        progress: Float = 0f,
        mediaType: AppMediaType = AppMediaType.AUDIOBOOK,
        seriesNumber: String? = null,
        libraryId: String = "library",
        connectionId: String = "connection",
    ) = Book(
        id = id,
        title = id,
        isFinished = finished,
        readProgress = progress,
        mediaType = mediaType,
        seriesName = "Series",
        seriesNumber = seriesNumber,
        source = BookSource.AUDIOBOOKSHELF,
        libraryId = libraryId,
        connectionId = connectionId,
    )
}
