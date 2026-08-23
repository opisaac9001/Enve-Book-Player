package com.enve.hearth.library

import com.enve.core.data.model.Book
import org.junit.Assert.assertEquals
import org.junit.Test

class LibraryExclusionFilterTest {

    @Test
    fun excludedLibrariesAreRemovedWhileUnscopedBooksRemainVisible() {
        val excluded = Book(id = "excluded", title = "Excluded", libraryId = "connection::hidden")
        val included = Book(id = "included", title = "Included", libraryId = "connection::visible")
        val unscoped = Book(id = "unscoped", title = "Unscoped")

        val visible = listOf(excluded, included, unscoped)
            .excludingLibraries(setOf("connection::hidden"))

        assertEquals(listOf(included, unscoped), visible)
    }

    @Test
    fun emptyExclusionSetKeepsEveryBook() {
        val books = listOf(
            Book(id = "one", title = "One", libraryId = "connection::one"),
            Book(id = "two", title = "Two"),
        )

        assertEquals(books, books.excludingLibraries(emptySet()))
    }
}
