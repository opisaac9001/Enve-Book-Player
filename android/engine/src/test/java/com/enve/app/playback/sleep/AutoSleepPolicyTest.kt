package com.enve.app.playback.sleep

import com.enve.engine.playback.SleepAutomationSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime

class AutoSleepPolicyTest {
    @Test
    fun windowWithinOneDay() {
        assertTrue(AutoSleepPolicy.isInWindow(13 * 60, 12 * 60, 14 * 60))
        assertFalse(AutoSleepPolicy.isInWindow(14 * 60, 12 * 60, 14 * 60))
        assertFalse(AutoSleepPolicy.isInWindow(11 * 60 + 59, 12 * 60, 14 * 60))
    }

    @Test
    fun windowAcrossMidnight() {
        assertTrue(AutoSleepPolicy.isInWindow(23 * 60, 22 * 60, 6 * 60))
        assertTrue(AutoSleepPolicy.isInWindow(2 * 60, 22 * 60, 6 * 60))
        assertFalse(AutoSleepPolicy.isInWindow(6 * 60, 22 * 60, 6 * 60))
        assertFalse(AutoSleepPolicy.isInWindow(12 * 60, 22 * 60, 6 * 60))
    }

    @Test
    fun emptyWindowNeverMatches() {
        assertFalse(AutoSleepPolicy.isInWindow(22 * 60, 22 * 60, 22 * 60))
    }

    @Test
    fun windowStartAfterMidnightBelongsToPreviousEvening() {
        val now = LocalDateTime.of(2026, 11, 15, 1, 30)
        assertEquals(LocalDateTime.of(2026, 11, 14, 22, 0), AutoSleepPolicy.currentWindowStart(now, 22 * 60))
    }

    @Test
    fun snoozeNeverShortensALongerTimer() {
        assertEquals(null, AutoSleepPolicy.snoozeMinutes(remainingSec = 30 * 60L, snoozeMinutes = 10))
        assertEquals(null, AutoSleepPolicy.snoozeMinutes(remainingSec = 10 * 60L, snoozeMinutes = 10))
    }

    @Test
    fun snoozeExtendsAShorterTimer() {
        assertEquals(10, AutoSleepPolicy.snoozeMinutes(remainingSec = 20L, snoozeMinutes = 10))
    }

    @Test
    fun snoozeRequiresARunningTimer() {
        assertEquals(null, AutoSleepPolicy.snoozeMinutes(remainingSec = 0, snoozeMinutes = 10))
        assertEquals(null, AutoSleepPolicy.snoozeMinutes(remainingSec = null, snoozeMinutes = 10))
    }

    @Test
    fun shakeIsOptIn() {
        assertFalse(SleepAutomationSettings().shakeToSnoozeEnabled)
    }

    @Test
    fun windowStartBeforeMidnightIsToday() {
        val now = LocalDateTime.of(2026, 11, 15, 22, 0)
        assertEquals(LocalDateTime.of(2026, 11, 15, 22, 0), AutoSleepPolicy.currentWindowStart(now, 22 * 60))
    }
}
