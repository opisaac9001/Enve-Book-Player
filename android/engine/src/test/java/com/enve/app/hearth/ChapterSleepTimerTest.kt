package com.enve.app.hearth

import org.junit.Assert.assertEquals
import org.junit.Test

class ChapterSleepTimerTest {

    @Test
    fun remainingTimeTracksPlaybackSpeedAndPosition() {
        val chapterEndMs = 1_200_000L

        assertEquals(1_200L, chapterSleepRemainingSeconds(chapterEndMs, 0L, 1f))
        assertEquals(960L, chapterSleepRemainingSeconds(chapterEndMs, 0L, 1.25f))
        assertEquals(300L, chapterSleepRemainingSeconds(chapterEndMs, 600_000L, 2f))
        assertEquals(0L, chapterSleepRemainingSeconds(chapterEndMs, chapterEndMs, 1f))
    }
}
