package com.enve.app.data.metadata

import com.enve.core.data.model.AppMediaType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MetadataScoringTest {
    @Test
    fun normalizeSearchQuery_removesBracketedParentheticalAndBracedText() {
        val normalized = MetadataScoring.normalizeSearchQuery("  Dune [Audible] (Unabridged) {Retail}  ")
        assertEquals("Dune", normalized)
    }

    @Test
    fun parseTitleAndAuthor_usesLastSeparator() {
        val parsed = MetadataScoring.parseTitleAndAuthor("The Blade Itself - First Law by Joe Abercrombie")
        assertEquals("The Blade Itself - First Law", parsed.first)
        assertEquals("Joe Abercrombie", parsed.second)
    }

    @Test
    fun defaultSearchQuery_doesNotDuplicateAuthorEmbeddedInTitle() {
        val query = MetadataScoring.defaultSearchQuery("Project Hail Mary - Andy Weir", "Andy Weir")
        assertEquals("Project Hail Mary by Andy Weir", query)
    }

    @Test
    fun defaultSearchQuery_matchesReversedAuthorNames() {
        val query = MetadataScoring.defaultSearchQuery("Project Hail Mary - Andy Weir", "Weir, Andy")
        assertEquals("Project Hail Mary by Weir, Andy", query)
    }

    @Test
    fun defaultSearchQuery_keepsDashSubtitleWhenAuthorDoesNotMatch() {
        val query = MetadataScoring.defaultSearchQuery("The Blade Itself - First Law", "Joe Abercrombie")
        assertEquals("The Blade Itself - First Law by Joe Abercrombie", query)
    }

    @Test
    fun defaultSearchQuery_keepsDashSubtitleWhenAuthorIsMissing() {
        val query = MetadataScoring.defaultSearchQuery("The Blade Itself - First Law", null)
        assertEquals("The Blade Itself - First Law", query)
    }

    @Test
    fun calculateAudioScore_exactTitleAuthorAndDurationIsHighConfidence() {
        val score = MetadataScoring.calculateAudioScore(
            file = MetadataMatchFileSnapshot(
                title = "The Hobbit",
                author = "J.R.R. Tolkien",
                durationSec = 39_600,
                isbn = null,
                seriesNumber = null,
            ),
            candidate = candidate(
                title = "The Hobbit",
                author = "J. R. R. Tolkien",
                durationSec = 39_590,
            ),
        )

        assertTrue(score.total >= 0.99)
        assertFalse(score.requiresManualReview)
    }

    @Test
    fun calculateAudioScore_seriesNumberMismatchAppliesPenalty() {
        val matched = MetadataScoring.calculateAudioScore(
            file = MetadataMatchFileSnapshot(
                title = "Book 1",
                author = "Author",
                durationSec = 10_000,
                isbn = null,
                seriesNumber = 1,
            ),
            candidate = candidate(title = "Book 1", author = "Author", durationSec = 10_000),
        )
        val mismatched = MetadataScoring.calculateAudioScore(
            file = MetadataMatchFileSnapshot(
                title = "Book 1",
                author = "Author",
                durationSec = 10_000,
                isbn = null,
                seriesNumber = 1,
            ),
            candidate = candidate(title = "Book 2", author = "Author", durationSec = 10_000),
        )

        assertTrue(matched.total > mismatched.total)
        assertTrue(mismatched.total <= matched.total - 0.25)
    }

    @Test
    fun calculateBookScore_exactIsbnOverridesTitleDifference() {
        val score = MetadataScoring.calculateBookScore(
            file = MetadataMatchFileSnapshot(
                title = "Wrong Local Title",
                author = null,
                durationSec = 0,
                isbn = "9780345339683",
                seriesNumber = null,
            ),
            title = "The Hobbit",
            authors = listOf("J.R.R. Tolkien"),
            isbn = "9780345339683",
        )

        assertEquals(1.0, score.total, 0.0)
        assertFalse(score.requiresManualReview)
    }

    @Test
    fun calculateBookScore_prefersActualBookOverSummaryWhenAuthorIsParsed() {
        val file = MetadataMatchFileSnapshot(
            title = "Project Hail Mary",
            author = "Andy Weir",
            durationSec = 0,
            isbn = null,
            seriesNumber = null,
        )
        val actual = MetadataScoring.calculateBookScore(
            file = file,
            title = "Project Hail Mary",
            authors = listOf("Andy Weir"),
            isbn = null,
        )
        val summary = MetadataScoring.calculateBookScore(
            file = file,
            title = "Summary of Project Hail Mary by Andy Weir",
            authors = listOf("Antoine McCallan"),
            isbn = null,
        )

        assertTrue(actual.total > summary.total)
        assertTrue(actual.total >= 0.99)
        assertTrue(summary.total < 0.75)
    }

    private fun candidate(
        title: String,
        author: String,
        durationSec: Long,
    ) = MetadataMatchCandidate(
        id = "audio:test",
        externalId = "B000000000",
        source = MetadataCandidateSource.AUDIOBOOK_CATALOG,
        mediaType = AppMediaType.AUDIOBOOK,
        title = title,
        author = author,
        authors = listOf(author),
        durationSec = durationSec,
        confidence = 0.0,
        matchReason = "",
    )
}
