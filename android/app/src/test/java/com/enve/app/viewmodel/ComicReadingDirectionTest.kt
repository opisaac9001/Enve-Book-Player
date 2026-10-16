package com.enve.app.viewmodel

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ComicReadingDirectionTest {
    @Test
    fun mapsKomgaReadingDirections() {
        assertEquals(ComicReadingDirection.LEFT_TO_RIGHT, mapProviderReadingDirection("LEFT_TO_RIGHT"))
        assertEquals(ComicReadingDirection.RIGHT_TO_LEFT, mapProviderReadingDirection("right_to_left"))
        assertEquals(ComicReadingDirection.VERTICAL, mapProviderReadingDirection("VERTICAL"))
        assertEquals(ComicReadingDirection.WEBTOON, mapProviderReadingDirection("WEBTOON"))
        assertNull(mapProviderReadingDirection(null))
        assertNull(mapProviderReadingDirection("UNKNOWN"))
    }

    @Test
    fun overrideKeysIsolateConnectionsWithMatchingBookIds() {
        val first = comicBookKey("book-1", BookSource.KOMGA, "komga-home")
        val second = comicBookKey("book-1", BookSource.KOMGA, "komga-remote")

        assertNotEquals(first, second)
        assertEquals("komga-home:book-1", first)
    }

    @Test
    fun providerMetadataWinsOverTitleHeuristics() = runBlocking {
        val manga = Book(id = "1", title = "Manga Volume 1", source = BookSource.KOMGA)
        assertEquals(ComicReadingDirection.LEFT_TO_RIGHT, resolveAutoComicReadingDirection(manga) { "LEFT_TO_RIGHT" })
        assertEquals(ComicReadingDirection.WEBTOON, resolveAutoComicReadingDirection(manga) { "WEBTOON" })
    }

    @Test
    fun missingOrUnknownMetadataFallsBackToHeuristicsThenLeftToRight() = runBlocking {
        val japanese = Book(id = "1", title = "Issue 1", language = "ja", source = BookSource.KOMGA)
        val manga = Book(id = "2", title = "Some Manga", source = BookSource.KOMGA)
        val western = Book(id = "3", title = "Issue 1", source = BookSource.KOMGA)
        assertEquals(ComicReadingDirection.RIGHT_TO_LEFT, resolveAutoComicReadingDirection(japanese) { null })
        assertEquals(ComicReadingDirection.RIGHT_TO_LEFT, resolveAutoComicReadingDirection(manga) { "" })
        assertEquals(ComicReadingDirection.LEFT_TO_RIGHT, resolveAutoComicReadingDirection(western) { null })
        assertEquals(ComicReadingDirection.LEFT_TO_RIGHT, resolveAutoComicReadingDirection(western) { "SIDEWAYS" })
    }

    @Test
    fun finalSpreadReportsTheBookAsFinished() {
        val entries = listOf(listOf(0), listOf(1, 2), listOf(3, 4))
        assertEquals(1f, comicReadProgress(3, 5, entries), 0f)
        assertEquals(3f / 5f, comicReadProgress(1, 5, entries), 0f)
        assertEquals(1f / 5f, comicReadProgress(0, 5, entries), 0f)
    }

    @Test
    fun singlePageProgressCountsTheVisiblePage() {
        assertEquals(1f, comicReadProgress(4, 5, emptyList()), 0f)
        assertEquals(2f / 5f, comicReadProgress(1, 5, emptyList()), 0f)
        assertEquals(1f, comicReadProgress(0, 1, listOf(listOf(0))), 0f)
    }
}
