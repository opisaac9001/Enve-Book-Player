package com.enve.core.data.model

import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class HistorySessionTest {
    @Test
    fun legacySessionDefaultsToLocalOrigin() {
        val session = Json.decodeFromString<HistorySession>(
            """{"id":"1","bookId":"2","bookKey":"connection:2","source":"BOOKORBIT","mediaType":"EBOOK","startTimeMs":1,"endTimeMs":2,"activeDurationSeconds":1}""",
        )

        assertEquals(HistorySessionOrigin.LOCAL, session.origin)
    }
}
