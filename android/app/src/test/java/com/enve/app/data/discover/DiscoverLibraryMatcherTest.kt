package com.enve.app.data.discover

import com.enve.core.data.model.Book
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DiscoverLibraryMatcherTest {

    @Test
    fun matchBook_prefers_isbn13_match() {
        val libraryBook = book(
            id = "library-1",
            title = "Different Title",
            author = "Different Author",
            isbn13 = "9780765326355",
        )
        val discover = discoverBook(
            title = "The Way of Kings",
            author = "Brandon Sanderson",
            collectionId = "9780765326355",
        )

        assertEquals(libraryBook, DiscoverLibraryMatcher.matchBook(discover, listOf(libraryBook)))
    }

    @Test
    fun matchBook_matches_audiobook_title_and_author_variants() {
        val libraryBook = book(
            id = "library-1",
            title = "Finding Faith",
            author = "B. E. Baker",
        )
        val discover = discoverBook(
            title = "Finding Faith: A Clean Romance Audiobook",
            author = "Bridget E. Baker",
        )

        assertEquals(libraryBook, DiscoverLibraryMatcher.matchBook(discover, listOf(libraryBook)))
    }

    @Test
    fun matchBook_rejects_low_confidence_title_only_match() {
        val libraryBook = book(
            id = "library-1",
            title = "Dune",
            author = "Frank Herbert",
        )
        val discover = discoverBook(
            title = "Dune Road",
            author = "Jane Green",
        )

        assertNull(DiscoverLibraryMatcher.matchBook(discover, listOf(libraryBook)))
    }

    @Test
    fun match_maps_discovered_ids_to_library_books() {
        val libraryBook = book(
            id = "library-1",
            title = "Project Hail Mary",
            author = "Andy Weir",
        )
        val discover = discoverBook(
            id = "discover-1",
            title = "Project Hail Mary (Unabridged)",
            author = "Andy Weir",
        )
        val section = DiscoverSection(
            id = DiscoverSectionId.TRENDING,
            title = "Trending",
            subtitle = "",
            books = listOf(discover),
        )

        assertEquals(mapOf("discover-1" to libraryBook), DiscoverLibraryMatcher.match(listOf(section), listOf(libraryBook)))
    }

    private fun book(
        id: String,
        title: String,
        author: String,
        isbn13: String? = null,
    ): Book =
        Book(
            id = id,
            title = title,
            author = author,
            isbn13 = isbn13,
        )

    private fun discoverBook(
        id: String = "discover",
        title: String,
        author: String,
        collectionId: String? = null,
    ): DiscoverBook =
        DiscoverBook(
            id = id,
            title = title,
            author = author,
            artworkUrl = null,
            description = null,
            publishedDate = null,
            genre = null,
            pageCount = null,
            durationMillis = null,
            previewUrl = null,
            infoUrl = null,
            collectionId = collectionId,
        )
}
