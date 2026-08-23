package com.enve.app.hearth

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BookOrbitCollectionPolicyTest {
    @Test
    fun acceptsOnlyDistinctBooksFromTheCollectionConnection() {
        val books = listOf(book("7"), book("9"), book("7"))

        assertEquals(listOf(7, 9), BookOrbitCollectionPolicy.bookIds("server", books))
    }

    @Test
    fun rejectsMixedConnections() {
        assertNull(BookOrbitCollectionPolicy.bookIds("server", listOf(book("7"), book("9", "other"))))
    }

    @Test
    fun rejectsNonBookOrbitBooks() {
        assertNull(BookOrbitCollectionPolicy.bookIds("server", listOf(book("7", source = BookSource.LOCAL))))
    }

    private fun book(
        id: String,
        connectionId: String = "server",
        source: BookSource = BookSource.BOOKORBIT,
    ) = Book(id = id, title = id, connectionId = connectionId, source = source)
}
