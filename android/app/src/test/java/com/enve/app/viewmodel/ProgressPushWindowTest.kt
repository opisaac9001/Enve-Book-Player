package com.enve.app.viewmodel

import org.junit.Assert.assertEquals
import org.junit.Test

class ProgressPushWindowTest {
    @Test
    fun steadySentenceChangesStillPushWithinTheMaxWait() {
        val window = ProgressPushWindow(debounceMs = 5_000, maxWaitMs = 15_000)

        assertEquals(5_000, window.delayMs(nowMs = 0))
        assertEquals(5_000, window.delayMs(nowMs = 3_000))
        assertEquals(5_000, window.delayMs(nowMs = 9_000))
        assertEquals(3_000, window.delayMs(nowMs = 12_000))
        assertEquals(0, window.delayMs(nowMs = 16_000))
    }

    @Test
    fun aPushStartsANewWindow() {
        val window = ProgressPushWindow(debounceMs = 5_000, maxWaitMs = 15_000)
        window.delayMs(nowMs = 0)
        window.delayMs(nowMs = 14_000)

        window.reset()

        assertEquals(5_000, window.delayMs(nowMs = 20_000))
        assertEquals(5_000, window.delayMs(nowMs = 29_000))
        assertEquals(1_000, window.delayMs(nowMs = 34_000))
    }
}
