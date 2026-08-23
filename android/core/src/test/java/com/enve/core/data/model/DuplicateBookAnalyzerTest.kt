package com.enve.core.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DuplicateBookAnalyzerTest {

    @Test
    fun exactTitleAndAuthorClustersAcrossProviders() {
        val clusters = DuplicateBookAnalyzer.findClusters(
            books = listOf(
                book(id = "a", title = "The Way of Kings", author = "Brandon Sanderson", source = BookSource.GRIMMORY),
                book(id = "b", title = "The Way of Kings", author = "Brandon Sanderson", source = BookSource.KOMGA),
                book(id = "c", title = "Words of Radiance", author = "Brandon Sanderson", source = BookSource.KOMGA),
            ),
            aggressiveness = MergeAggressiveness.NORMAL,
        )

        assertEquals(1, clusters.size)
        assertEquals(DuplicateMatchReason.EXACT_TITLE_AUTHOR, clusters.single().reason)
        assertEquals(98, clusters.single().confidence)
        assertEquals(setOf("a", "b"), clusters.single().books.map { it.id }.toSet())
    }

    @Test
    fun matchingIsbnWinsWithHighestConfidence() {
        val clusters = DuplicateBookAnalyzer.findClusters(
            books = listOf(
                book(id = "a", title = "Different Provider Title", isbn13 = "978-0-7653-2635-5"),
                book(id = "b", title = "The Way of Kings", isbn13 = "9780765326355"),
            ),
            aggressiveness = MergeAggressiveness.CONSERVATIVE,
        )

        assertEquals(1, clusters.size)
        assertEquals(DuplicateMatchReason.ISBN, clusters.single().reason)
        assertEquals(100, clusters.single().confidence)
    }

    @Test
    fun sameTitleAcrossAudioAndEbookDoesNotCluster() {
        val clusters = DuplicateBookAnalyzer.findClusters(
            books = listOf(
                book(id = "ebook", title = "Dune", author = "Frank Herbert", mediaType = AppMediaType.EBOOK),
                book(id = "audio", title = "Dune", author = "Frank Herbert", mediaType = AppMediaType.AUDIOBOOK),
            ),
            aggressiveness = MergeAggressiveness.AGGRESSIVE,
        )

        assertTrue(clusters.isEmpty())
    }

    @Test
    fun sameAudiobookTitleWithDifferentKnownDurationsDoesNotCluster() {
        val clusters = DuplicateBookAnalyzer.findClusters(
            books = listOf(
                book(id = "audio-a", title = "Novel 10", author = "Author", mediaType = AppMediaType.AUDIOBOOK, duration = 1_000L),
                book(id = "audio-b", title = "Novel 10", author = "Author", mediaType = AppMediaType.AUDIOBOOK, duration = 2_000L),
            ),
            aggressiveness = MergeAggressiveness.AGGRESSIVE,
        )

        assertTrue(clusters.isEmpty())
    }

    @Test
    fun thresholdControlsLooseTitleVariants() {
        val books = listOf(
            book(id = "a", title = "The Fellowship of the Ring", author = "J. R. R. Tolkien"),
            book(id = "b", title = "Fellowship of the Ring Special Edition", author = "JRR Tolkien"),
        )

        val conservative = DuplicateBookAnalyzer.findClusters(books, MergeAggressiveness.CONSERVATIVE)
        val normal = DuplicateBookAnalyzer.findClusters(books, MergeAggressiveness.NORMAL)

        assertTrue(conservative.isEmpty())
        assertEquals(1, normal.size)
        assertEquals(DuplicateMatchReason.SIMILAR_TITLE_AUTHOR, normal.single().reason)
    }

    @Test
    fun oneTokenPrefixTitlesDoNotCluster() {
        val clusters = DuplicateBookAnalyzer.findClusters(
            books = listOf(
                book(id = "dune", title = "Dune", author = "Frank Herbert"),
                book(id = "messiah", title = "Dune: Messiah", author = "Frank Herbert"),
            ),
            aggressiveness = MergeAggressiveness.AGGRESSIVE,
        )

        assertTrue(clusters.isEmpty())
    }

    @Test
    fun numberedBookPrefixesDoNotCollapseDifferentSeriesVolumes() {
        val clusters = DuplicateBookAnalyzer.findClusters(
            books = listOf(
                book(id = "one", title = "Book 1 - Novel", author = "Author", seriesName = "Series", seriesNumber = "1"),
                book(id = "two", title = "Book 2 - Novel", author = "Author", seriesName = "Series", seriesNumber = "2"),
            ),
            aggressiveness = MergeAggressiveness.AGGRESSIVE,
        )

        assertTrue(clusters.isEmpty())
    }

    private fun book(
        id: String,
        title: String,
        author: String = "Author",
        source: BookSource = BookSource.OPDS,
        mediaType: AppMediaType = AppMediaType.EBOOK,
        isbn13: String? = null,
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
            isbn13 = isbn13,
            duration = duration,
            seriesName = seriesName,
            seriesNumber = seriesNumber,
            connectionId = "${source.name.lowercase()}-conn",
        )
}
