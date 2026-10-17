package com.enve.app.readium

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ReadAloudPlaybackSpeedTest {
    @Test
    fun keepsSupportedSpeeds() {
        listOf(0.5f, 0.75f, 1.0f, 1.25f, 2.0f, 3.0f).forEach { speed ->
            assertEquals(speed, readAloudPlaybackSpeed(speed))
        }
    }

    @Test
    fun clampsOutOfRangeSpeeds() {
        assertEquals(0.5f, readAloudPlaybackSpeed(0.1f))
        assertEquals(0.5f, readAloudPlaybackSpeed(-2f))
        assertEquals(3.0f, readAloudPlaybackSpeed(8f))
    }

    @Test
    fun rejectsNonFiniteSpeeds() {
        assertNull(readAloudPlaybackSpeed(Float.NaN))
        assertNull(readAloudPlaybackSpeed(Float.POSITIVE_INFINITY))
        assertNull(readAloudPlaybackSpeed(Float.NEGATIVE_INFINITY))
    }

    @Test
    fun replacedSessionSelectionDoesNotChangeCurrentSessionSpeed() {
        val selection = ReadAloudSpeedSelection()
        selection.select("replaced", 3.0f)

        assertEquals(1.25f, selection.speedFor("current", prepared = 1.25f))
    }

    @Test
    fun pendingSelectionOverridesSpeedCapturedBeforePrepare() {
        val selection = ReadAloudSpeedSelection()
        selection.select("current", 2.0f)

        assertEquals(2.0f, selection.speedFor("current", prepared = 1.0f))
    }

    @Test
    fun noSelectionUsesPreparedSpeed() {
        assertEquals(1.5f, ReadAloudSpeedSelection().speedFor("current", prepared = 1.5f))
    }

    @Test
    fun speedChosenWhileStoppedWinsOnNextPlay() {
        val selection = ReadAloudSpeedSelection()
        selection.select("current", 2.0f)
        selection.select("current", 1.25f)

        assertEquals(1.25f, selection.speedFor("current", prepared = 1.25f))
        assertEquals(1.25f, selection.speedFor("current", prepared = 2.0f))
    }

    @Test
    fun invalidSelectionKeepsPreviousSpeed() {
        val selection = ReadAloudSpeedSelection()
        selection.select("current", 1.5f)

        assertNull(selection.select("current", Float.NaN))
        assertEquals(1.5f, selection.speedFor("current", prepared = 1.0f))
    }
}
