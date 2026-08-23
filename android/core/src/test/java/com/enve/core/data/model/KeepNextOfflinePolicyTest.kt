package com.enve.core.data.model

import com.enve.core.data.local.KeepNextOfflineSettings
import org.junit.Assert.assertEquals
import org.junit.Test

class KeepNextOfflinePolicyTest {
    @Test
    fun seriesCandidatesFollowFractionalOrderAndSkipFinishedBooks() {
        val books = listOf(
            book("three", sequence = "3"),
            book("one", sequence = "1"),
            book("two-and-a-half", sequence = "2.5"),
            book("two", sequence = "2"),
            book("four", sequence = "4", finished = true),
        )

        val candidates = KeepNextOfflinePolicy.seriesCandidates(books[3], books)

        assertEquals(listOf("two-and-a-half", "three"), candidates.map(Book::id))
    }

    @Test
    fun seriesCandidatesStayWithinTheCurrentLibraryAndConnection() {
        val current = book("current", sequence = "1")
        val books = listOf(
            current,
            book("next", sequence = "2"),
            book("other-library", sequence = "3", libraryId = "other"),
            book("other-connection", sequence = "4", connectionId = "other"),
        )

        assertEquals(
            listOf("next"),
            KeepNextOfflinePolicy.seriesCandidates(current, books).map(Book::id),
        )
    }

    @Test
    fun aLaterDownloadDoesNotShrinkTheImmediateOfflineWindow() {
        val candidates = listOf("two", "three", "four", "five").map { book(it) }

        val needed = KeepNextOfflinePolicy.downloadsNeeded(
            candidates = candidates,
            targetCount = 3,
            isKeptOffline = { it.id == "five" },
        )

        assertEquals(listOf("two", "three", "four"), needed.map(Book::id))
    }

    @Test
    fun unsupportedPersistedCountsReturnToTheDefault() {
        assertEquals(5, KeepNextOfflineSettings.normalizeCount(5))
        assertEquals(1, KeepNextOfflineSettings.normalizeCount(4))
    }

    private fun book(
        id: String,
        sequence: String? = null,
        finished: Boolean = false,
        libraryId: String = "library",
        connectionId: String = "connection",
    ) = Book(
        id = id,
        title = id,
        seriesName = "Series",
        seriesNumber = sequence,
        isFinished = finished,
        libraryId = libraryId,
        connectionId = connectionId,
        source = BookSource.AUDIOBOOKSHELF,
        mediaType = AppMediaType.AUDIOBOOK,
    )
}
