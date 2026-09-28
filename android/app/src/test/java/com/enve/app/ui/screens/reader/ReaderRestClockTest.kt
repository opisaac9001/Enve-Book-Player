package com.enve.app.ui.screens.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderRestClockTest {
    @Test
    fun countsOnlyForegroundReading() {
        val clock = ReaderRestClock()
        clock.restart(0L)
        clock.pause(600_000L)
        clock.resume(660_000L)

        assertEquals(900_000L, clock.elapsedMs(960_000L))
    }

    @Test
    fun longBreakCountsAsRest() {
        val clock = ReaderRestClock()
        clock.restart(0L)
        clock.pause(1_200_000L)

        assertTrue(clock.resume(1_200_000L + ReaderRestClock.RESTING_GAP_MS))
        assertEquals(30_000L, clock.elapsedMs(1_200_000L + ReaderRestClock.RESTING_GAP_MS + 30_000L))
    }

    @Test
    fun shortBreakKeepsReadingTime() {
        val clock = ReaderRestClock()
        clock.restart(0L)
        clock.pause(300_000L)

        assertFalse(clock.resume(360_000L))
        assertEquals(300_000L, clock.elapsedMs(360_000L))
    }

    @Test
    fun pausedClockDoesNotAdvance() {
        val clock = ReaderRestClock()
        clock.restart(0L)
        clock.pause(120_000L)

        assertFalse(clock.isRunning)
        assertEquals(120_000L, clock.elapsedMs(10_000_000L))
    }

    @Test
    fun resumeWhileRunningIsIgnored() {
        val clock = ReaderRestClock()
        clock.restart(0L)

        assertFalse(clock.resume(50_000L))
        assertEquals(100_000L, clock.elapsedMs(100_000L))
    }
}
