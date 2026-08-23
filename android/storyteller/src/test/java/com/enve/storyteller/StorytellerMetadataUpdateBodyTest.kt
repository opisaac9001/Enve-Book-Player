package com.enve.storyteller

import com.enve.core.data.provider.ProviderMetadataUpdate
import okhttp3.MultipartBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class StorytellerMetadataUpdateBodyTest {

    @Test
    fun mapsProviderMetadataToStorytellerMultipartBody() {
        val body = ProviderMetadataUpdate(
            title = " Dune ",
            subtitle = " Deluxe Edition ",
            author = "Frank Herbert, Brian Herbert",
            narrator = "Simon Vance, Scott Brick",
            description = " A desert planet novel. ",
            seriesName = "Dune",
            seriesNumber = "1.5",
            publishedDate = "1965-08-01",
            language = "en",
            categories = listOf(" Science Fiction ", "", "Classic"),
        ).toStorytellerMetadataUpdateBody() as MultipartBody

        assertEquals(
            listOf("title", "subtitle", "language", "description", "publicationDate", "authors", "narrators", "tags", "series"),
            body.values("fields"),
        )
        assertEquals(listOf("\"Dune\""), body.values("title"))
        assertEquals(listOf("\"Deluxe Edition\""), body.values("subtitle"))
        assertEquals(listOf("\"en\""), body.values("language"))
        assertEquals(listOf("\"A desert planet novel.\""), body.values("description"))
        assertEquals(listOf("\"1965-08-01T00:00:00.000Z\""), body.values("publicationDate"))
        assertEquals(listOf("\"Frank Herbert\"", "\"Brian Herbert\""), body.values("authors"))
        assertEquals(listOf("\"Simon Vance\"", "\"Scott Brick\""), body.values("narrators"))
        assertEquals(listOf("\"Science Fiction\"", "\"Classic\""), body.values("tags"))
        assertEquals(listOf("{\"name\":\"Dune\",\"position\":1.5}"), body.values("series"))
    }

    @Test
    fun blankFieldsClearSupportedStorytellerMetadata() {
        val body = ProviderMetadataUpdate(
            title = "Title",
            subtitle = " ",
            author = " ",
            narrator = null,
            description = null,
            seriesName = "",
            publishedDate = null,
            language = "",
            categories = emptyList(),
        ).toStorytellerMetadataUpdateBody() as MultipartBody

        assertEquals(listOf("\"Title\""), body.values("title"))
        assertEquals(listOf("null"), body.values("subtitle"))
        assertEquals(listOf("null"), body.values("language"))
        assertEquals(listOf("null"), body.values("description"))
        assertEquals(listOf("null"), body.values("publicationDate"))
        assertEquals(emptyList<String>(), body.values("authors"))
        assertEquals(emptyList<String>(), body.values("narrators"))
        assertEquals(emptyList<String>(), body.values("tags"))
        assertEquals(emptyList<String>(), body.values("series"))
        assertTrue(body.values("fields").containsAll(listOf("authors", "narrators", "tags", "series")))
    }

    @Test
    fun invalidStorytellerPublicationDateFailsBeforeNetworkCall() {
        try {
            ProviderMetadataUpdate(
                title = "Title",
                publishedDate = "not-a-date",
            ).toStorytellerMetadataUpdateBody()
            fail("Expected invalid publication date to throw")
        } catch (e: IllegalArgumentException) {
            assertEquals("Storyteller publication date must be YYYY, YYYY-MM, YYYY-MM-DD, or ISO-8601", e.message)
        }
    }

    private fun MultipartBody.values(name: String): List<String> =
        parts.mapNotNull { part ->
            val disposition = part.headers?.get("Content-Disposition").orEmpty()
            if (!disposition.contains("name=\"$name\"")) return@mapNotNull null
            part.body.asString()
        }

    private fun okhttp3.RequestBody.asString(): String {
        val buffer = okio.Buffer()
        writeTo(buffer)
        return buffer.readUtf8()
    }
}
