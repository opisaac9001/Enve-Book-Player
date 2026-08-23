package com.enve.app.playback

import com.enve.core.data.model.Chapter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackChapterStoreTest {
    private val snapshot = PlaybackChapterStore.Snapshot(
        chapters = listOf(
            Chapter(index = 0, title = "One", startTime = 0, endTime = 60),
            Chapter(index = 1, title = "Two", startTime = 60, endTime = 120),
            Chapter(index = 2, title = "Three", startTime = 120, endTime = 180),
        ),
    )

    @Test
    fun nextChapterUsesAbsoluteChapterStart() {
        assertEquals(60L, snapshot.nextChapterStart(45))
        assertEquals(120L, snapshot.nextChapterStart(75))
        assertNull(snapshot.nextChapterStart(150))
    }

    @Test
    fun previousChapterRestartsOrMovesBackAfterThreshold() {
        assertEquals(60L, snapshot.previousChapterStart(90))
        assertEquals(0L, snapshot.previousChapterStart(61))
        assertEquals(0L, snapshot.previousChapterStart(2))
    }

    @Test
    fun zeroDurationTrackChaptersUseMediaItemIndexes() {
        val trackChapters = PlaybackChapterStore.Snapshot(
            chapters = listOf(
                Chapter(index = 0, title = "One", startTime = 0, endTime = 0),
                Chapter(index = 1, title = "Two", startTime = 0, endTime = 0),
                Chapter(index = 2, title = "Three", startTime = 0, endTime = 0),
            ),
        )

        assertTrue(trackChapters.usesMediaItemIndexes(mediaItemCount = 3))
        assertFalse(trackChapters.usesMediaItemIndexes(mediaItemCount = 1))
        assertFalse(snapshot.usesMediaItemIndexes(mediaItemCount = 3))
    }
}
