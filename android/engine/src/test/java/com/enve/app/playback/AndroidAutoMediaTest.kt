package com.enve.app.playback

import androidx.media3.common.MimeTypes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
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
    fun `Storyteller audiobook file fallback uses the M4B media type`() {
        assertEquals(
            MimeTypes.AUDIO_MP4,
            AudioPlaybackManager.guessMimeType(
                "https://example.test/api/v2/books/book-id/files?format=audiobook",
            ),
        )
    }
}
