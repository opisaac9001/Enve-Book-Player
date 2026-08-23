package com.enve.app.data.repository

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import org.junit.Assert.assertEquals
import org.junit.Test

class AggregatorConnectionSelectionTest {
    @Test
    fun `storyteller book never uses audiobookshelf connection id`() {
        val storyteller = connection("storyteller", BookSource.STORYTELLER)
        val audiobookshelf = connection("abs", BookSource.AUDIOBOOKSHELF)
        val book = Book(
            id = "book",
            title = "Book",
            author = "Author",
            mediaType = AppMediaType.EBOOK,
            source = BookSource.STORYTELLER,
            connectionId = audiobookshelf.id,
        )

        assertEquals(storyteller, selectConnectionForBook(book, listOf(audiobookshelf, storyteller)))
    }

    @Test
    fun `matching connection id wins among same-source connections`() {
        val first = connection("storyteller-1", BookSource.STORYTELLER)
        val selected = connection("storyteller-2", BookSource.STORYTELLER)
        val book = Book(
            id = "book",
            title = "Book",
            author = "Author",
            mediaType = AppMediaType.EBOOK,
            source = BookSource.STORYTELLER,
            connectionId = selected.id,
        )

        assertEquals(selected, selectConnectionForBook(book, listOf(first, selected)))
    }

    @Test
    fun `primitive storyteller routing rejects audiobookshelf connection id`() {
        val storyteller = connection("storyteller", BookSource.STORYTELLER)
        val audiobookshelf = connection("abs", BookSource.AUDIOBOOKSHELF)

        assertEquals(
            storyteller,
            selectConnectionForSource(
                source = BookSource.STORYTELLER,
                connectionId = audiobookshelf.id,
                connections = listOf(audiobookshelf, storyteller),
            ),
        )
    }

    private fun connection(id: String, source: BookSource) = ProviderConnection(
        id = id,
        source = source,
        name = id,
        serverUrl = "http://localhost",
        username = "tester",
    )
}
