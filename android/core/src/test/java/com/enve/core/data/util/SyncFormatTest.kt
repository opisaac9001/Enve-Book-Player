package com.enve.core.data.util

import org.junit.Assert.assertEquals
import org.junit.Test

class SyncFormatTest {

    @Test
    fun audiobook_position_ms_resolves_to_seconds_when_duration_is_unknown() {
        val seconds = resolveAudiobookPositionSeconds(
            positionMs = 600_000L,
            percentage = 0.0298f,
            durationSeconds = 0L,
            duration = 0.0,
        )

        assertEquals(600L, seconds)
    }

    @Test
    fun audiobook_position_ms_clamps_to_known_duration() {
        val seconds = resolveAudiobookPositionSeconds(
            positionMs = 25_000_000L,
            percentage = 0.5f,
            durationSeconds = 20_000L,
            duration = null,
        )

        assertEquals(20_000L, seconds)
    }

    @Test
    fun audiobook_position_falls_back_to_percentage_when_position_is_missing() {
        val seconds = resolveAudiobookPositionSeconds(
            positionMs = null,
            percentage = 0.25f,
            durationSeconds = 1_000L,
            duration = null,
        )

        assertEquals(250L, seconds)
    }
}
