package com.enve.komga

import com.enve.core.data.provider.ProviderMetadataUpdate
import com.enve.komga.dto.KomgaBookDto
import com.enve.komga.dto.KomgaBookMetadataDto
import com.enve.komga.dto.displayMetadata
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Test

class KomgaMetadataUpdatePayloadTest {

    @Test
    fun usesSeriesTitleAndIssueNumberForComicDisplayTitle() {
        val display = KomgaBookDto(
            id = "book-7",
            seriesId = "series-justice-league-dark",
            seriesTitle = "Justice League Dark",
            libraryId = "library-1",
            name = "Justice League Dark #7.cbz",
            metadata = KomgaBookMetadataDto(title = "#7", number = "#7"),
        ).displayMetadata()

        assertEquals("Justice League Dark - #7", display.title)
        assertEquals("Justice League Dark", display.seriesName)
        assertEquals("#7", display.seriesNumber)
    }

    @Test
    fun preservesDescriptiveComicTitleWithoutDuplicatingSeriesName() {
        val display = KomgaBookDto(
            id = "book-7",
            seriesId = "series-justice-league-dark",
            seriesTitle = "Justice League Dark",
            libraryId = "library-1",
            name = "Justice League Dark 7.cbz",
            metadata = KomgaBookMetadataDto(title = "Justice League Dark: The Parliament of Life", number = "7"),
        ).displayMetadata()

        assertEquals("Justice League Dark: The Parliament of Life", display.title)
        assertEquals("Justice League Dark", display.seriesName)
        assertEquals("7", display.seriesNumber)
    }

    @Test
    fun mapsProviderMetadataToKomgaPatchPayload() {
        val payload = ProviderMetadataUpdate(
            title = " Dune ",
            author = "Frank Herbert, Brian Herbert",
            description = " A desert planet novel. ",
            seriesNumber = "1.5",
            publishedDate = "1965",
            isbn13 = "9780441172719",
            narrator = "Simon Vance",
            publisher = "Ace",
            language = "en",
        ).toKomgaBookMetadataPatchJson()

        assertEquals(JsonPrimitive("Dune"), payload["title"])
        assertEquals(JsonPrimitive("A desert planet novel."), payload["summary"])
        assertEquals(JsonPrimitive("1.5"), payload["number"])
        assertEquals(JsonPrimitive(1.5f), payload["numberSort"])
        assertEquals(JsonPrimitive("1965-01-01"), payload["releaseDate"])
        assertEquals(JsonPrimitive("9780441172719"), payload["isbn"])

        val authors = payload["authors"]!!.jsonArray
        assertEquals(JsonPrimitive("Frank Herbert"), authors[0].jsonObject["name"])
        assertEquals(JsonPrimitive("writer"), authors[0].jsonObject["role"])
        assertEquals(JsonPrimitive("Brian Herbert"), authors[1].jsonObject["name"])
        assertFalse(payload.containsKey("narrator"))
        assertFalse(payload.containsKey("publisher"))
        assertFalse(payload.containsKey("language"))
    }

    @Test
    fun blankFieldsClearSupportedKomgaMetadata() {
        val payload = ProviderMetadataUpdate(
            title = "Title",
            author = " ",
            description = null,
            seriesNumber = null,
            publishedDate = null,
            isbn13 = null,
        ).toKomgaBookMetadataPatchJson()

        assertEquals(JsonPrimitive("Title"), payload["title"])
        assertEquals(JsonNull, payload["summary"])
        assertEquals(JsonNull, payload["number"])
        assertEquals(JsonNull, payload["numberSort"])
        assertEquals(JsonNull, payload["releaseDate"])
        assertEquals(emptyList<Any>(), payload["authors"]!!.jsonArray)
        assertEquals(JsonNull, payload["isbn"])
    }

    @Test
    fun invalidKomgaReleaseDateFailsBeforeNetworkCall() {
        try {
            ProviderMetadataUpdate(
                title = "Title",
                publishedDate = "not-a-date",
            ).toKomgaBookMetadataPatchJson()
            fail("Expected invalid release date to throw")
        } catch (e: IllegalArgumentException) {
            assertEquals("Komga release date must be YYYY, YYYY-MM, or YYYY-MM-DD", e.message)
        }
    }
}
