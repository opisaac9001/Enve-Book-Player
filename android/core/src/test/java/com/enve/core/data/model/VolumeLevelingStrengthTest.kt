package com.enve.core.data.model

import org.junit.Assert.assertEquals
import org.junit.Test

class VolumeLevelingStrengthTest {

    @Test
    fun persistedValueIsParsedCaseInsensitively() {
        assertEquals(VolumeLevelingStrength.LOW, VolumeLevelingStrength.fromString("low"))
        assertEquals(VolumeLevelingStrength.MEDIUM, VolumeLevelingStrength.fromString("MEDIUM"))
        assertEquals(VolumeLevelingStrength.HIGH, VolumeLevelingStrength.fromString("High"))
    }

    @Test
    fun missingOrUnknownValueDefaultsToOff() {
        assertEquals(VolumeLevelingStrength.OFF, VolumeLevelingStrength.fromString(null))
        assertEquals(VolumeLevelingStrength.OFF, VolumeLevelingStrength.fromString("unknown"))
    }
}
