package com.enve.audiobookshelf

import com.enve.core.data.provider.ProviderMetadataUpdate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AbsMetadataUpdatePayloadTest {

    @Test
    fun mapsProviderMetadataToAudiobookshelfPayload() {
        val payload = ProviderMetadataUpdate(
            title = " Dune ",
            subtitle = " Deluxe Edition ",
            author = "Frank Herbert, Brian Herbert",
            narrator = "Simon Vance, Scott Brick",
            description = " A desert planet novel. ",
            seriesName = "Dune",
            seriesNumber = "1",
            publisher = "Ace",
            publishedDate = "1965-08-01",
            isbn13 = "9780441172719",
            language = "en",
            categories = listOf(" Science Fiction ", "", "Classic"),
        ).toAbsMetadataUpdatePayload()

        assertEquals("Dune", payload.title)
        assertEquals("Deluxe Edition", payload.subtitle)
        assertEquals(listOf("Frank Herbert", "Brian Herbert"), payload.authors?.map { it.name })
        assertEquals(listOf("Simon Vance", "Scott Brick"), payload.narrators)
        assertEquals("Dune", payload.series?.single()?.name)
        assertEquals("1", payload.series?.single()?.sequence)
        assertEquals("1965", payload.publishedYear)
        assertEquals("1965-08-01", payload.publishedDate)
        assertEquals("Ace", payload.publisher)
        assertEquals("A desert planet novel.", payload.description)
        assertEquals("9780441172719", payload.isbn)
        assertEquals("en", payload.language)
        assertEquals(listOf("Science Fiction", "Classic"), payload.genres)
    }

    @Test
    fun blankFieldsClearSupportedAudiobookshelfMetadata() {
        val payload = ProviderMetadataUpdate(
            title = "Title",
            author = " ",
            narrator = null,
            seriesName = "",
            publishedDate = "not-a-year",
            categories = emptyList(),
        ).toAbsMetadataUpdatePayload()

        assertEquals("Title", payload.title)
        assertEquals(emptyList<String>(), payload.authors)
        assertEquals(emptyList<String>(), payload.narrators)
        assertEquals(emptyList<Any>(), payload.series)
        assertNull(payload.publishedYear)
        assertEquals("not-a-year", payload.publishedDate)
        assertNull(payload.genres)
    }
}
