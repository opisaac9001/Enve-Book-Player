package com.enve.app.playback.sleep

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ShakeDetectorTest {
    @Test
    fun restingPhoneNeverShakes() {
        val detector = ShakeDetector()
        repeat(100) { assertFalse(detector.onSample(0.0, 0.0, 1.0, it * 20L)) }
    }

    @Test
    fun twoPeaksInsideWindowShake() {
        val detector = ShakeDetector()
        assertFalse(detector.onSample(3.0, 0.0, 0.0, 0L))
        assertFalse(detector.onSample(0.0, 0.0, 1.0, 100L))
        assertTrue(detector.onSample(0.0, 3.0, 0.0, 300L))
    }

    @Test
    fun peaksOutsideWindowDoNotShake() {
        val detector = ShakeDetector()
        assertFalse(detector.onSample(3.0, 0.0, 0.0, 0L))
        assertFalse(detector.onSample(0.0, 0.0, 1.0, 100L))
        assertFalse(detector.onSample(3.0, 0.0, 0.0, 600L))
    }

    @Test
    fun oneSustainedMotionCountsAsOnePeak() {
        val detector = ShakeDetector()
        repeat(100) { assertFalse(detector.onSample(3.0, 0.0, 0.0, it * 20L)) }
    }

    @Test
    fun cooldownSuppressesRepeatShakes() {
        val detector = ShakeDetector()
        fun peak(at: Long): Boolean {
            detector.onSample(0.0, 0.0, 1.0, at)
            return detector.onSample(3.0, 0.0, 0.0, at + 10)
        }
        assertFalse(peak(0L))
        assertTrue(peak(100L))
        assertFalse(peak(200L))
        assertFalse(peak(300L))
        assertFalse(peak(1_200L))
        assertTrue(peak(1_300L))
    }
}
