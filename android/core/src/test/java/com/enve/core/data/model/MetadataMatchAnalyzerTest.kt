package com.enve.core.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MetadataMatchAnalyzerTest {

    @Test
    fun findsBooksMissingRichMetadata() {
        val unmatched = MetadataMatchAnalyzer.unmatchedBooks(
            books = listOf(
                book(id = "sparse", title = "Sparse Book", author = "Author"),
                book(
                    id = "rich",
                    title = "Rich Book",
                    author = "Author",
                    description = "Description",
                    publisher = "Publisher",
                    publishedDate = "2024",
                    isbn13 = "9781234567890",
                    language = "en",
                    pageCount = 320,
                ),
            ),
            locallyMatchedKeys = emptySet(),
        )

        assertEquals(1, unmatched.size)
        assertEquals("sparse", unmatched.single().book.id)
        assertTrue(unmatched.single().missingFields.contains("description"))
    }

    @Test
    fun localOverrideMarksBookAsMatched() {
        val target = book(id = "book", title = "Book", author = "Author")

        val unmatched = MetadataMatchAnalyzer.unmatchedBooks(
            books = listOf(target),
            locallyMatchedKeys = setOf(target.uniqueKey),
        )

        assertTrue(unmatched.isEmpty())
    }

    @Test
    fun exactTitleAndAuthorScoresHigh() {
        val candidate = MetadataMatchAnalyzer.scoreCandidate(
            book = book(id = "book", title = "The Fifth Season", author = "N. K. Jemisin"),
            provider = MetadataMatchProvider.GOOGLE_BOOKS,
            id = "candidate",
            title = "Fifth Season",
            author = "N.K. Jemisin",
            publisher = "Orbit",
            publishedDate = "2015",
            pageCount = 512,
            seriesName = null,
            seriesNumber = null,
            isbn13 = "9780316229296",
            language = "en",
            description = "A novel.",
        )

        assertNotNull(candidate)
        assertTrue(candidate!!.confidence >= 96)
        assertEquals("Exact title and author", candidate.matchReason)
    }

    @Test
    fun isbnMatchWinsEvenWhenTitleDiffers() {
        val candidate = MetadataMatchAnalyzer.scoreCandidate(
            book = book(id = "book", title = "Provider Title", author = "Author", isbn13 = "978-0-7653-2635-5"),
            provider = MetadataMatchProvider.OPEN_LIBRARY,
            id = "candidate",
            title = "Canonical Title",
            author = "Other",
            publisher = null,
            publishedDate = null,
            pageCount = null,
            seriesName = null,
            seriesNumber = null,
            isbn13 = "9780765326355",
            language = null,
            description = null,
        )

        assertNotNull(candidate)
        assertEquals(100, candidate!!.confidence)
        assertEquals("ISBN match", candidate.matchReason)
    }

    @Test
    fun unrelatedCandidateIsRejected() {
        val candidate = MetadataMatchAnalyzer.scoreCandidate(
            book = book(id = "book", title = "Dune", author = "Frank Herbert"),
            provider = MetadataMatchProvider.GOOGLE_BOOKS,
            id = "candidate",
            title = "Pride and Prejudice",
            author = "Jane Austen",
            publisher = null,
            publishedDate = null,
            pageCount = null,
            seriesName = null,
            seriesNumber = null,
            isbn13 = null,
            language = null,
            description = null,
        )

        assertNull(candidate)
    }

    @Test
    fun oneTokenSeriesPrefixCandidateIsRejected() {
        val candidate = MetadataMatchAnalyzer.scoreCandidate(
            book = book(id = "book", title = "Dune", author = "Frank Herbert"),
            provider = MetadataMatchProvider.OPEN_LIBRARY,
            id = "candidate",
            title = "Dune Messiah",
            author = "Frank Herbert",
            publisher = "Publisher",
            publishedDate = "1969",
            pageCount = 300,
            seriesName = null,
            seriesNumber = null,
            isbn13 = null,
            language = "en",
            description = null,
        )

        assertNull(candidate)
    }

    private fun book(
        id: String,
        title: String,
        author: String? = null,
        description: String? = null,
        publisher: String? = null,
        publishedDate: String? = null,
        isbn13: String? = null,
        language: String? = null,
        pageCount: Int? = null,
    ): Book =
        Book(
            id = id,
            title = title,
            author = author,
            description = description,
            publisher = publisher,
            publishedDate = publishedDate,
            isbn13 = isbn13,
            language = language,
            pageCount = pageCount,
            source = BookSource.OPDS,
            mediaType = AppMediaType.EBOOK,
            connectionId = "metadata-test",
        )
}
