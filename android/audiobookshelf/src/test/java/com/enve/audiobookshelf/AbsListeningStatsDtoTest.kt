package com.enve.audiobookshelf

import com.enve.audiobookshelf.dto.AbsListeningStatsDto
import com.enve.audiobookshelf.dto.AbsMeResponse
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AbsListeningStatsDtoTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun decodesListeningStatsIgnoringItemMap() {
        val stats = json.decodeFromString<AbsListeningStatsDto>(
            """
            {"totalTime":7500.5,"today":600,
             "days":{"2025-08-11":3600,"2025-08-12":3900.5},
             "dayOfWeek":{"Monday":3600,"Tuesday":3900.5},
             "items":{"li_1":{"id":"li_1","timeListening":3600}},
             "recentSessions":[{"id":"s1"}]}
            """.trimIndent(),
        )

        assertEquals(7500.5, stats.totalTime, 0.0001)
        assertEquals(600.0, stats.today, 0.0001)
        assertEquals(2, stats.days.size)
        assertEquals(3900.5, stats.dayOfWeek.getValue("Tuesday"), 0.0001)
    }

    @Test
    fun decodesEmptyListeningStats() {
        val stats = json.decodeFromString<AbsListeningStatsDto>("""{"totalTime":0,"items":{},"days":{}}""")

        assertEquals(0.0, stats.totalTime, 0.0001)
        assertTrue(stats.days.isEmpty())
        assertTrue(stats.dayOfWeek.isEmpty())
    }

    @Test
    fun decodesBookmarksFromProfile() {
        val me = json.decodeFromString<AbsMeResponse>(
            """{"id":"u1","bookmarks":[{"libraryItemId":"li_1","title":"Chapter three","time":930.4,"createdAt":1754992800000}],"mediaProgress":[]}""",
        )

        val bookmark = me.bookmarks.single()
        assertEquals("li_1", bookmark.libraryItemId)
        assertEquals("Chapter three", bookmark.title)
        assertEquals(930.4, bookmark.time, 0.0001)
        assertEquals(1_754_992_800_000L, bookmark.createdAt)
    }
}
