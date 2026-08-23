package com.enve.hearth.library

import com.enve.core.data.model.Book
import org.junit.Assert.assertEquals
import org.junit.Test

class SeriesPlaybackOrderTest {
    @Test
    fun ordersNumberedBooksNaturallyAndLeavesUnnumberedLast() {
        val books = listOf(
            book("appendix", null),
            book("ten", "10"),
            book("two", "Book 2"),
            book("one-half", "1.5"),
            book("one", "1"),
        )

        assertEquals(
            listOf("one", "one-half", "two", "ten", "appendix"),
            seriesPlaybackOrder(books).map(Book::id),
        )
    }

    private fun book(id: String, number: String?) = Book(
        id = id,
        title = id,
        seriesName = "Series",
        seriesNumber = number,
    )
}
