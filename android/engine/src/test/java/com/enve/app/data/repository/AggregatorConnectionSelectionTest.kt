package com.enve.app.data.repository

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AggregatorConnectionSelectionTest {
    @Test
    fun `same numeric id on two connections keeps both books`() {
        val first = Book(id = "12", title = "Romeo and Juliet", mediaType = AppMediaType.EBOOK, source = BookSource.GRIMMORY, connectionId = "grimmory-a")
        val second = first.copy(title = "Hamlet", connectionId = "grimmory-b")

        assertEquals(listOf(first, second), listOf(first, second, first).distinctBy(::catalogIdentity))
    }

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

        assertNull(selectConnectionForBook(book, listOf(audiobookshelf, storyteller)))
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

        assertNull(
            selectConnectionForSource(
                source = BookSource.STORYTELLER,
                connectionId = audiobookshelf.id,
                connections = listOf(audiobookshelf, storyteller),
            ),
        )
    }

    @Test
    fun explicitDisabledOrRemovedConnectionCannotSelectAnotherAccount() {
        val a = connection("a", BookSource.AUDIOBOOKSHELF).copy(enabled = false)
        val b = connection("b", BookSource.AUDIOBOOKSHELF)
        assertNull(selectConnectionForSource(BookSource.AUDIOBOOKSHELF, a.id, listOf(a, b)))
        assertNull(selectConnectionForSource(BookSource.AUDIOBOOKSHELF, a.id, listOf(b)))
        assertEquals(b, selectConnectionForSource(BookSource.AUDIOBOOKSHELF, null, listOf(a, b)))
    }

    @Test
    fun bookEditIsDispatchedOnlyToTheAccountItWasMadeOn() {
        val source = BookSource.BOOKORBIT
        val account = "http://localhost|tester"
        val a = connection("a", source)
        val b = connection("b", source).copy(username = "other")

        assertEquals(a, selectConnectionForBookEdit(source, a.id, account, listOf(a, b)).getOrThrow())
        assertTrue(selectConnectionForBookEdit(source, a.id, account, listOf(a.copy(username = "other"), b)).isFailure)
        assertTrue(selectConnectionForBookEdit(source, a.id, account, listOf(a.copy(serverUrl = "http://elsewhere"), b)).isFailure)
        assertTrue(selectConnectionForBookEdit(source, a.id, account, listOf(a.copy(enabled = false), b)).isFailure)
        assertTrue(selectConnectionForBookEdit(source, a.id, account, listOf(b)).isFailure)
        assertTrue(selectConnectionForBookEdit(source, a.id, account, emptyList()).isFailure)
    }

    @Test
    fun bookEditWithoutConnectionIdNeverFallsBackToADifferentAccount() {
        val source = BookSource.BOOKORBIT
        val a = connection("a", source)
        val other = connection("abs", BookSource.AUDIOBOOKSHELF)

        assertNull(selectConnectionForBookEdit(source, null, "", listOf(other)).getOrThrow())
        assertTrue(selectConnectionForBookEdit(source, null, "", listOf(a)).isFailure)
        assertTrue(selectConnectionForBookEdit(source, null, "http://localhost|tester", emptyList()).isFailure)
        assertEquals(a, selectConnectionForBookEdit(source, null, "http://localhost|tester", listOf(a, other)).getOrThrow())
        assertTrue(
            selectConnectionForBookEdit(
                source, null, "http://localhost|tester", listOf(a, connection("b", source)),
            ).isFailure,
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
