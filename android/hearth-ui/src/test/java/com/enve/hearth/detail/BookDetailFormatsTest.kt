package com.enve.hearth.detail

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class BookDetailFormatsTest {
    @Test
    fun localNarrationDetectionSurvivesServerDetailMerge() {
        val summary = Book(id = "42", title = "EPUB", source = BookSource.GRIMMORY, mediaType = AppMediaType.EBOOK)
        val local = summary.copy(readAlongAvailable = true, hasAudio = true, hasEbook = true)
        assertTrue(mergeBookDetail(summary, local).readAlongAvailable)
        assertTrue(mergeBookDetail(local, summary).readAlongAvailable)
        assertSame(local, detailListenTarget(local, null))
    }

    @Test
    fun hydratedFormatsSurviveCatalogUpdatesForEitherPrimaryFormat() {
        for (type in listOf(AppMediaType.AUDIOBOOK, AppMediaType.EBOOK)) {
            val summary = Book(
                id = "42",
                title = "Mixed formats",
                source = BookSource.GRIMMORY,
                mediaType = type,
                hasAudio = type == AppMediaType.AUDIOBOOK,
                hasEbook = type == AppMediaType.EBOOK,
                currentTime = 23L,
            )
            val detail = summary.copy(hasAudio = true, hasEbook = true)
            val merged = mergeBookDetail(summary, detail)
            assertTrue(merged.hasAudio)
            assertTrue(merged.hasEbook)
            assertEquals(type, merged.mediaType)
            assertEquals(23L, merged.currentTime)
            assertSame(merged, detailListenTarget(merged, null))
            val refreshed = mergeBookDetail(summary.copy(title = "Refreshed"), detail)
            assertTrue(refreshed.hasAudio)
            assertTrue(refreshed.hasEbook)
        }
    }

    @Test
    fun missingDetailsPreserveCatalog() {
        val book = Book(id = "42", title = "Book", source = BookSource.GRIMMORY)
        assertSame(book, mergeBookDetail(book, null))
    }

    @Test
    fun grimmoryCombinedFormatsOpenTheirOwnEdition() {
        val ebook = Book(
            id = "42",
            title = "Combined formats",
            source = BookSource.GRIMMORY,
            mediaType = AppMediaType.EBOOK,
            hasAudio = true,
            hasEbook = true,
        )
        val audiobook = ebook.copy(id = "grimmory-ab-42", mediaType = AppMediaType.AUDIOBOOK)

        assertSame(ebook, detailReadTarget(audiobook, ebook))
        assertSame(audiobook, detailListenTarget(ebook, audiobook))
        assertSame(ebook, detailReadTarget(ebook, null))
        assertSame(audiobook, detailListenTarget(audiobook, null))
    }
}
