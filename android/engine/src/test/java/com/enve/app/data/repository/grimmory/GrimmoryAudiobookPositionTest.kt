package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.dto.AudiobookInfoDto
import com.enve.app.data.remote.dto.AudiobookProgressDto
import com.enve.app.data.remote.dto.TrackDto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GrimmoryAudiobookPositionTest {

    private fun track(index: Int, durationMs: Long, cumulativeStartMs: Long?) =
        TrackDto(index = index, durationMs = durationMs, cumulativeStartMs = cumulativeStartMs)

    @Test
    fun single_file_position_is_already_global() {
        val ab = AudiobookProgressDto(positionMs = 275_000L, trackIndex = null)
        assertEquals(275_000L, grimmoryGlobalAudiobookPositionMs(ab, null))
    }

    @Test
    fun track_zero_is_treated_as_global() {
        val ab = AudiobookProgressDto(positionMs = 275_000L, trackIndex = 0)
        assertEquals(275_000L, grimmoryGlobalAudiobookPositionMs(ab, null))
    }

    @Test
    fun multi_file_offset_reconstructs_to_global() {
        val info = AudiobookInfoDto(
            bookId = "1",
            folderBased = true,
            tracks = listOf(
                track(0, 600_000L, 0L),
                track(1, 600_000L, 600_000L),
                track(2, 600_000L, 1_200_000L),
            ),
        )

        val ab = AudiobookProgressDto(positionMs = 30_000L, trackIndex = 2)
        assertEquals(1_230_000L, grimmoryGlobalAudiobookPositionMs(ab, info.trackStartsByIndex()))
    }

    @Test
    fun multi_file_without_layout_yields_null_for_percentage_fallback() {
        val ab = AudiobookProgressDto(positionMs = 30_000L, trackIndex = 5)
        assertNull(grimmoryGlobalAudiobookPositionMs(ab, null))
    }

    @Test
    fun write_read_round_trips_across_track_boundaries() {

        val starts = mapOf(0 to 0L, 1 to 600_000L, 2 to 1_050_000L, 3 to 1_800_000L)
        val globals = listOf(
            0L, 59_000L,
            600_000L, 900_000L,
            1_050_000L, 1_799_999L,
            1_800_000L, 2_000_000L,
        )
        for (g in globals) {
            val wire = grimmoryEncodeAudiobookPosition(globalMs = g, multiFile = true, trackStartsByIndex = starts)
            val ab = AudiobookProgressDto(positionMs = wire.positionData.toLong(), trackIndex = wire.positionHref?.toInt())
            assertEquals("global $g must survive a write→read round trip", g, grimmoryGlobalAudiobookPositionMs(ab, starts))
        }
    }

    @Test
    fun single_file_write_read_round_trips() {
        val g = 275_000L
        val wire = grimmoryEncodeAudiobookPosition(globalMs = g, multiFile = false, trackStartsByIndex = null)
        assertNull(wire.positionHref)
        val ab = AudiobookProgressDto(positionMs = wire.positionData.toLong(), trackIndex = wire.positionHref?.toInt())
        assertEquals(g, grimmoryGlobalAudiobookPositionMs(ab, null))
    }

    @Test
    fun track_starts_fall_back_to_running_duration_sum_when_absent() {
        val info = AudiobookInfoDto(
            bookId = "1",
            tracks = listOf(
                track(0, 600_000L, null),
                track(1, 450_000L, null),
                track(2, 600_000L, null),
            ),
        )
        assertEquals(mapOf(0 to 0L, 1 to 600_000L, 2 to 1_050_000L), info.trackStartsByIndex())
    }
}
