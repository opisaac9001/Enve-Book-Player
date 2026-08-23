package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.dto.BookSummaryDto
import com.enve.core.data.model.AppMediaType
import org.junit.Assert.assertEquals
import org.junit.Test

class GrimmorySummaryMappingTest {
    @Test
    fun audiobookUsesTopLevelPrimaryFileNameAndSummaryMetadata() {
        val book = BookSummaryDto(
            id = "75",
            title = "Spellmonger",
            authors = listOf("Terry Mancour"),
            primaryFileType = "M4B",
            primaryFileName = "Marshal Arcane.m4b",
            narrator = "John Lee",
            publisher = "Podium Audio",
            categories = listOf("Fantasy"),
            language = "en",
            isbn13 = "9781039414723",
        ).toBook("http://grimmory.test")

        assertEquals("Marshal Arcane", book.title)
        assertEquals("John Lee", book.narrator)
        assertEquals("Podium Audio", book.publisher)
        assertEquals(listOf("Fantasy"), book.categories)
        assertEquals("en", book.language)
        assertEquals("9781039414723", book.isbn13)
    }

    @Test
    fun audiobookGridCoverUsesThumbnailEndpoint() {
        assertEquals(
            "/api/v1/media/book/75/audiobook-thumbnail",
            rewriteLegacyCoverPath("/api/books/75/cover", AppMediaType.AUDIOBOOK),
        )
        assertEquals(
            "/api/v1/media/book/75/audiobook-thumbnail",
            fallbackCoverPath("75", AppMediaType.AUDIOBOOK),
        )
    }
}
