package com.enve.app.viewmodel

import com.enve.core.data.model.BookSource
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
}
