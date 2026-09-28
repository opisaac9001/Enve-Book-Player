package com.enve.storyteller

import com.enve.storyteller.dto.StorytellerBookDto
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StorytellerImportParsingTest {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = true
    }

    @Test
    fun skipsMalformedArrayItemsButKeepsValidBooks() {
        val payload = """
            [
              "broken",
              {
                "uuid": "book-1",
                "title": "Valid Book",
                "audiobook": {
                  "filepath": "Shelf/Valid Book/audio.mp3",
                  "missing": false
                }
              }
            ]
        """.trimIndent()

        val decoded = decodeLenientStorytellerArray<StorytellerBookDto>(json, payload)

        assertEquals(1, decoded.skippedCount)
        assertEquals(1, decoded.values.size)

        val imported = mapStorytellerBook(decoded.values.single(), "https://storyteller.example")
        assertNotNull(imported)
        assertEquals("book-1", imported?.id)
        assertEquals("Valid Book", imported?.title)
        assertEquals(
            "https://storyteller.example/api/v2/books/book-1/cover?w=400&audio=true",
            imported?.coverUrl,
        )
    }

    @Test
    fun importsAlignedReadaloudWithoutSeparateEbookOrAudiobook() {
        val payload = """
            [{"uuid":"readaloud-only","title":"Aligned Book",
              "readaloud":{"filepath":"aligned/book.epub","status":"ALIGNED","missing":false}}]
        """.trimIndent()
        val decoded = decodeLenientStorytellerArray<StorytellerBookDto>(json, payload)
        val imported = mapStorytellerBook(decoded.values.single(), "https://storyteller.example")

        assertNotNull(imported)
        assertEquals(com.enve.core.data.model.AppMediaType.EBOOK, imported!!.mediaType)
        assertEquals("EPUB", imported.primaryFileType)
        assertTrue(imported.readAlongAvailable)
        assertTrue(imported.hasEbook)
        assertTrue(imported.hasAudio)
    }

    @Test
    fun missingIdAndTitleStillImportWithFallbacks() {
        val payload = """
            [
              {
                "audiobook": {
                  "filepath": "Authors/Unknown Masterpiece/audio.mp3",
                  "missing": false
                }
              }
            ]
        """.trimIndent()

        val decoded = decodeLenientStorytellerArray<StorytellerBookDto>(json, payload)
        val imported = mapStorytellerBook(decoded.values.single(), "https://storyteller.example")

        assertNotNull(imported)
        assertTrue(imported!!.id.startsWith("storyteller-missing-book-"))
        assertEquals("Unknown Masterpiece", imported.title)
        assertNull(imported.coverUrl)
        assertNull(storytellerServerBookIdOrNull(imported.id))
    }
}
