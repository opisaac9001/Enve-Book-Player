package com.enve.core.data.model

import org.junit.Assert.assertEquals
import org.junit.Test

class BookVisibilityTest {

    @Test
    fun exclusionUsesCompositeLibraryIdentity() {
        val first = book("first", "connection-a", "connection-a::manga")
        val second = book("second", "connection-b", "connection-b::manga")

        val visible = listOf(first, second).visibleLibraryBooks(setOf("connection-a::manga"))

        assertEquals(listOf(second), visible)
    }

    @Test
    fun deduplicationRunsAfterExclusionAndKeepsVisibleConnection() {
        val hiddenCopy = book("same", "connection-a", "connection-a::hidden")
        val visibleCopy = book("same", "connection-b", "connection-b::visible")

        val visible = listOf(hiddenCopy, visibleCopy)
            .visibleLibraryBooks(setOf("connection-a::hidden"))

        assertEquals(listOf(visibleCopy), visible)
    }

    @Test
    fun booksWithoutLibraryRemainVisible() {
        val book = book("unscoped", "connection-a", null)

        assertEquals(listOf(book), listOf(book).visibleLibraryBooks(setOf("connection-a::hidden")))
    }

    private fun book(id: String, connectionId: String, libraryId: String?) = Book(
        id = id,
        title = id,
        source = BookSource.KOMGA,
        connectionId = connectionId,
        libraryId = libraryId,
    )
}
