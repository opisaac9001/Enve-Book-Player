package com.enve.core.reader

import org.junit.Assert.*
import org.junit.Test

class ReadingSpeedTrackerTest {
    @Test fun regularReadingProducesAnEstimateAfterWarmup() {
        val tracker = ReadingSpeedTracker()
        for (page in 0..3) tracker.recordPageTurn(0.1 + page / 1000.0, 1000, page * 20_000L)
        assertEquals(0.003, tracker.progressPerMinute!!, 0.000001)
        assertNotNull(tracker.minutesRemaining(0.5))
    }

    @Test fun jumpsFlicksBacktrackingAndIdleDoNotTeachAPace() {
        val tracker = ReadingSpeedTracker()
        for ((progress, time) in listOf(0.1 to 0L, 0.8 to 20_000L, 0.801 to 21_000L, 0.5 to 40_000L, 0.501 to 700_000L)) {
            tracker.recordPageTurn(progress, 1000, time)
        }
        assertNull(tracker.progressPerMinute)
        for (page in 1..3) tracker.recordPageTurn(0.501 + page / 1000.0, 1000, 700_000L + page * 20_000L)
        assertEquals(0.003, tracker.progressPerMinute!!, 0.000001)
    }

    @Test fun pauseAndInvalidSamplesResetTheBaseline() {
        val tracker = ReadingSpeedTracker()
        tracker.recordPageTurn(0.1, 1000, 0)
        tracker.pause()
        tracker.recordPageTurn(0.101, 1000, 200_000)
        tracker.recordPageTurn(Double.NaN, 1000, 220_000)
        tracker.recordPageTurn(0.102, 1000, 240_000)
        assertNull(tracker.progressPerMinute)
        assertNull(tracker.minutesRemaining(Double.NaN))
    }

    @Test fun outlierIsBoundedAndPaceSurvivesPause() {
        val tracker = ReadingSpeedTracker()
        for (page in 0..3) tracker.recordPageTurn(0.1 + page / 1000.0, 1000, page * 20_000L)
        tracker.recordPageTurn(0.104, 1000, 560_000)
        assertEquals(0.0024, tracker.progressPerMinute!!, 0.000001)
        tracker.pause()
        assertNotNull(tracker.minutesRemaining(0.5))
        tracker.reset()
        assertNull(tracker.minutesRemaining(0.5))
    }
}
