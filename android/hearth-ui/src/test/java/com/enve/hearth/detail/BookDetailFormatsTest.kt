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
}
