package com.enve.bookorbit

import com.enve.bookorbit.dto.BookOrbitBookmarkDto
import com.enve.bookorbit.dto.BookOrbitBookmarkRequest
import com.enve.bookorbit.dto.BookOrbitReadingSessionsPageDto
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class BookOrbitUserDataDtoTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun decodesEbookAndAudiobookBookmarks() {
        val ebook = json.decodeFromString<BookOrbitBookmarkDto>(
            """{"id":7,"bookId":1,"cfi":"epubcfi(/6/2!)","title":"Chapter","createdAt":"2026-08-12T10:00:00Z"}""",
        )
        val audio = json.decodeFromString<BookOrbitBookmarkDto>(
            """{"id":8,"bookId":2,"title":"Moment","positionSeconds":42.5,"createdAt":"2026-08-12T10:00:00Z"}""",
        )

        assertEquals("epubcfi(/6/2!)", ebook.cfi)
        assertEquals(42.5, audio.positionSeconds!!, 0.0)
    }

    @Test
    fun bookmarkRequestUsesExactlyOneLocationKind() {
        val payload = json.parseToJsonElement(
            json.encodeToString(BookOrbitBookmarkRequest(cfi = "epubcfi(/6/2!)", title = "Chapter")),
        ).jsonObject

        assertEquals("epubcfi(/6/2!)", payload.getValue("cfi").jsonPrimitive.content)
        assertFalse(payload.containsKey("positionSeconds"))
    }

    @Test
    fun decodesPagedReadingSessions() {
        val page = json.decodeFromString<BookOrbitReadingSessionsPageDto>(
            """{"items":[{"id":3,"startedAt":"2026-08-12T10:00:00Z","endedAt":"2026-08-12T10:01:07Z","durationSeconds":67,"progressDelta":2.0,"endProgress":42.0}],"total":1,"page":1,"pageSize":100}""",
        )

        assertEquals(1, page.total)
        assertEquals(67, page.items.single().durationSeconds)
        assertEquals(42.0, page.items.single().endProgress!!, 0.0)
    }
}
