package com.enve.core.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BookLinkAnalyzerTest {
    @Test
    fun linksEbookAndAudiobookWithSameWorkIdentity() {
        val ebook = book(
            id = "ebook",
            title = "Project Hail Mary",
            author = "Andy Weir",
            mediaType = AppMediaType.EBOOK,
            source = BookSource.GRIMMORY,
        )
        val audiobook = book(
            id = "audio",
            title = "Project Hail Mary (Unabridged)",
            author = "Andy Weir",
            mediaType = AppMediaType.AUDIOBOOK,
            source = BookSource.AUDIOBOOKSHELF,
            duration = 57960L,
        )

        val links = BookLinkAnalyzer.findPairs(listOf(ebook, audiobook))

        assertEquals(1, links.size)
        assertEquals(ebook.uniqueKey, links.single().ebook.uniqueKey)
        assertEquals(audiobook.uniqueKey, links.single().audiobook.uniqueKey)
    }

    @Test
    fun ignoresBracketedMetadataTagsInTitles() {
        val links = BookLinkAnalyzer.findPairs(
            listOf(
                book(id = "ebook", title = "Dune {Retail}", author = "Frank Herbert", mediaType = AppMediaType.EBOOK),
                book(id = "audio", title = "Dune (Unabridged)", author = "Frank Herbert", mediaType = AppMediaType.AUDIOBOOK),
            ),
        )

        assertEquals(1, links.size)
    }

    @Test
    fun doesNotLinkAdjacentSeriesVolumes() {
        val books = listOf(
            book(id = "ebook-1", title = "Dune", author = "Frank Herbert", mediaType = AppMediaType.EBOOK, seriesName = "Dune", seriesNumber = "1"),
            book(id = "audio-2", title = "Dune Messiah", author = "Frank Herbert", mediaType = AppMediaType.AUDIOBOOK, seriesName = "Dune", seriesNumber = "2"),
        )

        assertTrue(BookLinkAnalyzer.findPairs(books).isEmpty())
    }

    @Test
    fun doesNotLinkNumberedPrefixVolumesWithSameBaseTitle() {
        val books = listOf(
            book(id = "ebook-1", title = "Book 1 - Novel", author = "Author", mediaType = AppMediaType.EBOOK, seriesName = "Series", seriesNumber = "1"),
            book(id = "audio-2", title = "Book 2 - Novel", author = "Author", mediaType = AppMediaType.AUDIOBOOK, seriesName = "Series", seriesNumber = "2"),
        )

        assertTrue(BookLinkAnalyzer.findPairs(books).isEmpty())
    }

    @Test
    fun reciprocalBestPreventsOneAudiobookLinkingSeveralEbooks() {
        val audiobook = book(id = "audio", title = "The Lost Metal", author = "Brandon Sanderson", mediaType = AppMediaType.AUDIOBOOK)
        val exact = book(id = "ebook-exact", title = "The Lost Metal", author = "Brandon Sanderson", mediaType = AppMediaType.EBOOK)
        val loose = book(id = "ebook-loose", title = "Lost Metal", author = "Brandon Sanderson", mediaType = AppMediaType.EBOOK)

        val links = BookLinkAnalyzer.findPairs(listOf(audiobook, exact, loose))

        assertEquals(listOf("ebook-exact"), links.map { it.ebook.id })
    }

    @Test
    fun rankMatchesIncludesManualFallbacksAndPrefersSameConnection() {
        val audiobook = book(
            id = "audio",
            title = "Unhelpfully Named Audio",
            author = "Author",
            mediaType = AppMediaType.AUDIOBOOK,
            source = BookSource.AUDIOBOOKSHELF,
        )
        val sameConnection = book(
            id = "ebook-same-connection",
            title = "Completely Different",
            author = "Other",
            mediaType = AppMediaType.EBOOK,
            source = BookSource.KOMGA,
        ).copy(connectionId = audiobook.connectionId)
        val otherConnection = book(
            id = "ebook-other-connection",
            title = "Another Different",
            author = "Other",
            mediaType = AppMediaType.EBOOK,
            source = BookSource.KOMGA,
        )

        val ranked = BookLinkAnalyzer.rankMatches(
            forBook = audiobook,
            books = listOf(audiobook, otherConnection, sameConnection),
        )

        assertEquals(listOf("ebook-same-connection", "ebook-other-connection"), ranked.map { it.book.id })
        assertTrue(ranked.all { it.confidence == 0 })
    }

    private fun book(
        id: String,
        title: String,
        author: String,
        mediaType: AppMediaType,
        source: BookSource = BookSource.OPDS,
        duration: Long = 0L,
        seriesName: String? = null,
        seriesNumber: String? = null,
    ): Book =
        Book(
            id = id,
            title = title,
            author = author,
            source = source,
            mediaType = mediaType,
            duration = duration,
            seriesName = seriesName,
            seriesNumber = seriesNumber,
            connectionId = "${source.name.lowercase()}-conn",
        )
}
