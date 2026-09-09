package com.enve.app.playback

import androidx.media3.common.MimeTypes
import com.enve.core.data.model.Chapter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidAutoMediaTest {
    @Test
    fun `track media IDs remain unique while resolving to the same book`() {
        val first = AutoMediaBrowserHelper.mediaIdForTrack("server:book", 0)
        val second = AutoMediaBrowserHelper.mediaIdForTrack("server:book", 1)

        assertNotEquals(first, second)
        assertEquals("server:book", AutoMediaBrowserHelper.cacheKeyFrom(first))
        assertEquals("server:book", AutoMediaBrowserHelper.cacheKeyFrom(second))
    }

    @Test
    fun `chapter media IDs remain unique while resolving to the same book`() {
        val first = AutoMediaBrowserHelper.mediaIdForChapter("server:book", 0)
        val second = AutoMediaBrowserHelper.mediaIdForChapter("server:book", 1)

        assertNotEquals(first, second)
        assertTrue(AutoMediaBrowserHelper.isChapterMediaId(first))
        assertEquals("server:book", AutoMediaBrowserHelper.cacheKeyFrom(first))
    }

    @Test
    fun `single file chapters become resumable queue segments`() {
        val segments = AutoMediaBrowserHelper.chapterSegments(
            chapters = listOf(
                Chapter(index = 0, title = "Opening", startTime = 0, endTime = 30),
                Chapter(index = 1, title = "One", startTime = 30, endTime = 90),
                Chapter(index = 2, title = "Two", startTime = 90, endTime = 150),
            ),
            totalDurationMs = 150_000,
        )

        assertEquals(listOf(30_000L, 60_000L, 60_000L), segments.map { it.endMs - it.startMs })
        assertEquals(1 to 15_000L, AutoMediaBrowserHelper.startOffsetInSegments(segments, 45_000L))
    }

    @Test
    fun `Storyteller audiobook file fallback uses the M4B media type`() {
        assertEquals(
            MimeTypes.AUDIO_MP4,
            AudioPlaybackManager.guessMimeType(
                "https://example.test/api/v2/books/book-id/files?format=audiobook",
            ),
        )
    }
}
