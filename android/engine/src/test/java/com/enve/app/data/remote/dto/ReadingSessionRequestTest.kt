package com.enve.app.data.remote.dto

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.float
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ReadingSessionRequestTest {
    @Test
    fun encodesGrimmoryReadingSessionContract() {
        val request = ReadingSessionRequest(
            bookId = 42,
            bookType = "EPUB",
            startTime = "2026-08-04T12:00:00Z",
            endTime = "2026-08-04T12:02:05Z",
            durationSeconds = 125,
            durationFormatted = "2m 5s",
            startProgress = 12.5f,
            endProgress = 15f,
            progressDelta = 2.5f,
            startLocation = "10",
            endLocation = "12",
        )

        val json = Json.parseToJsonElement(Json.encodeToString(request)).jsonObject

        assertEquals(42, json.getValue("bookId").jsonPrimitive.int)
        assertEquals("EPUB", json.getValue("bookType").jsonPrimitive.content)
        assertEquals(125, json.getValue("durationSeconds").jsonPrimitive.int)
        assertEquals(12.5f, json.getValue("startProgress").jsonPrimitive.float)
        assertEquals(15f, json.getValue("endProgress").jsonPrimitive.float)
        assertEquals(2.5f, json.getValue("progressDelta").jsonPrimitive.float)
        assertFalse(json.containsKey("durationMs"))
        assertFalse(json.containsKey("mediaType"))
    }
}
