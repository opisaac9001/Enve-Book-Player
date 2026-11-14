package com.enve.core.data.local

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ComicMetadata
import com.enve.core.data.model.ComicSection
import com.enve.core.data.model.isComic
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CachedBookComicMetadataTest {
    private val metadata = ComicMetadata(
        seriesId = "28",
        section = ComicSection.VOLUMES,
        volumeId = "34",
        volumeTitle = "Volume 2",
        volumeOrder = 2.0,
        issueLabel = "#5",
        issueOrder = 5.0,
    )

    private fun issue(comic: ComicMetadata?, fileType: String? = "CBZ") = Book(
        id = "28:34:55",
        title = "Saga #5",
        source = BookSource.KAVITA,
        mediaType = AppMediaType.EBOOK,
        connectionId = "conn-1",
        primaryFileType = fileType,
        comic = comic,
    )

    @Test
    fun comicHierarchySurvivesTheCacheRoundTrip() {
        val cached = issue(metadata).toCachedBook(nowMs = 1L)

        assertEquals(metadata, cached.toBook().comic)
    }

    @Test
    fun rowsCachedBeforeTheColumnExistedReadAsFlatBooks() {
        val cached = issue(metadata).toCachedBook(nowMs = 1L).copy(comicMetadataJson = null)

        assertNull(cached.toBook().comic)
        assertTrue(cached.toBook().isComic)
    }

    @Test
    fun unreadableMetadataIsIgnored() {
        val cached = issue(metadata).toCachedBook(nowMs = 1L).copy(comicMetadataJson = "{")

        assertNull(cached.toBook().comic)
    }

    @Test
    fun comicDetectionRequiresAnEbook() {
        assertTrue(issue(metadata, fileType = "PDF").isComic)
        assertFalse(issue(null, fileType = "EPUB").isComic)
        assertFalse(issue(metadata).copy(mediaType = AppMediaType.AUDIOBOOK).isComic)
    }
}
