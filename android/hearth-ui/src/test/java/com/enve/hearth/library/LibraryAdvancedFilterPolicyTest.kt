package com.enve.hearth.library

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryAdvancedFilterPolicyTest {
    @Test
    fun combinesFacetsWhileKeepingSelectionsWithinFacetInclusive() {
        val fantasy = book(
            "fantasy",
            categories = listOf("Fantasy", "Adventure"),
            language = "English",
            rating = 4.4f,
            series = "Earthsea",
        )
        val mystery = book(
            "mystery",
            categories = listOf("Mystery"),
            language = "English",
            rating = 4.2f,
        )
        val translated = book(
            "translated",
            categories = listOf("Fantasy"),
            language = "Spanish",
            rating = 4.8f,
            series = "Saga",
        )
        val filters = LibraryAdvancedFilters(
            genres = setOf("Fantasy", "Mystery"),
            languages = setOf("English"),
            minimumRating = 4f,
        )

        assertTrue(LibraryAdvancedFilterPolicy.matches(fantasy, filters))
        assertTrue(LibraryAdvancedFilterPolicy.matches(mystery, filters))
        assertFalse(LibraryAdvancedFilterPolicy.matches(translated, filters))
    }

    @Test
    fun ratingAndSeriesPresenceNarrowTogether() {
        val seriesBook = book(
            "series",
            categories = listOf("Science Fiction"),
            language = "English",
            rating = 4.5f,
            series = "The Expanse",
        )
        val standalone = book(
            "standalone",
            categories = listOf("Science Fiction"),
            language = "English",
            rating = 4.8f,
        )
        val filters = LibraryAdvancedFilters(
            minimumRating = 4.5f,
            series = SeriesFilter.IN_SERIES,
        )

        assertTrue(LibraryAdvancedFilterPolicy.matches(seriesBook, filters))
        assertFalse(LibraryAdvancedFilterPolicy.matches(standalone, filters))
    }

    @Test
    fun optionsDeduplicateCaseAndWhitespace() {
        val first = book(
            "one",
            categories = listOf(" Fantasy ", "Adventure"),
            language = "English",
        )
        val second = book(
            "two",
            categories = listOf("fantasy"),
            language = " english ",
        )

        val options = LibraryAdvancedFilterPolicy.options(listOf(first, second))

        assertEquals(2, options.genres.size)
        assertEquals(listOf("English"), options.languages)
    }

    private fun book(
        id: String,
        categories: List<String>,
        language: String,
        rating: Float? = null,
        series: String? = null,
    ) = Book(
        id = id,
        title = id,
        categories = categories,
        language = language,
        goodreadsRating = rating,
        seriesName = series,
        source = BookSource.LOCAL,
        connectionId = "unit",
        libraryId = "library",
    )
}
