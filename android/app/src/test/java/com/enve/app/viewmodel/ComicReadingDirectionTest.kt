package com.enve.app.viewmodel

import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import com.enve.app.ui.screens.parseComicInfoReadingDirection

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
    fun metadataWinsOverEveryDefaultIncludingScroll() {
        for (defaultDirection in ComicReadingDirection.entries) {
            for (defaultProgression in ComicProgressionMode.entries) {
                val defaults = ComicReaderSettings(readingDirection = defaultDirection, progressionMode = defaultProgression)
                for (metadata in ComicReadingDirection.entries) {
                    val resolved = resolveComicReaderSettings(defaults, null, metadata)
                    assertEquals(metadata, resolved.readingDirection)
                    assertEquals(
                        if (metadata.isStrip) ComicProgressionMode.VERTICAL_STRIP else ComicProgressionMode.PAGED,
                        resolved.progressionMode,
                    )
                }
                assertEquals(defaults, resolveComicReaderSettings(defaults, null, null))
            }
        }
    }

    @Test
    fun explicitBookChoiceWinsUntilAutoIsSelected() {
        val defaults = ComicReaderSettings(readingDirection = ComicReadingDirection.WEBTOON)
        val override = resolveComicReaderSettings(defaults, ComicReadingDirection.LEFT_TO_RIGHT, ComicReadingDirection.RIGHT_TO_LEFT)
        assertEquals(ComicReadingDirection.LEFT_TO_RIGHT, override.readingDirection)
        assertEquals(ComicProgressionMode.PAGED, override.progressionMode)
        assertEquals(ComicReadingDirection.RIGHT_TO_LEFT, resolveComicReaderSettings(defaults, null, ComicReadingDirection.RIGHT_TO_LEFT).readingDirection)
    }

    @Test
    fun comicInfoOnlySuppliesExplicitDirection() {
        fun parse(value: String) = parseComicInfoReadingDirection(
            "<ComicInfo><Manga>$value</Manga></ComicInfo>".byteInputStream(),
        )
        assertEquals(ComicReadingDirection.RIGHT_TO_LEFT, parse(" YesAndRightToLeft "))
        assertEquals(ComicReadingDirection.LEFT_TO_RIGHT, parse("Yes"))
        assertEquals(ComicReadingDirection.LEFT_TO_RIGHT, parse("No"))
        assertNull(parse("Unknown"))
        assertNull(parseComicInfoReadingDirection("<ComicInfo><Title>Manga</Title></ComicInfo>".byteInputStream()))
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
