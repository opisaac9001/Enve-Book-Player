package com.enve.app.playback.ambient

import org.junit.Assert.assertEquals
import org.junit.Test

class AmbientFadeScaleTest {
    @Test
    fun fullVolumeWithoutTimer() = assertEquals(1f, ambientFadeScale(null), 0f)

    @Test
    fun fullVolumeOutsideFadeWindow() = assertEquals(1f, ambientFadeScale(300L), 0f)

    @Test
    fun followsSleepFade() {
        assertEquals(0f, ambientFadeScale(0L), 0f)
        assertEquals(0.5f, ambientFadeScale(15L), 0.001f)
        assertEquals(1f / 30f, ambientFadeScale(1L), 0.001f)
    }
}
