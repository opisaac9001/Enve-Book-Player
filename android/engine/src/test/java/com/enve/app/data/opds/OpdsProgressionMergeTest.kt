package com.enve.app.data.opds

import com.enve.core.data.model.BookSource
import com.enve.core.data.sync.SyncSnapshot
import org.junit.Assert.assertEquals
import org.junit.Test

class OpdsProgressionMergeTest {

    private val now = 1_700_000_000_000L
    private val earlier = now - 10L * 60_000L

    @Test
    fun a_newer_remote_progression_wins_when_nothing_is_playing() {
        val decision = opdsProgressionDecision(
            localPercentage = 0.20f,
            localUpdatedAtMs = earlier,
            remote = remote(0.60f, updatedAt = now - 5_000L),
            playbackSessionActive = false,
        )

        assertEquals(OpdsProgressionDecision.PULL, decision)
    }

    @Test
    fun a_newer_local_progression_is_pushed() {
        val decision = opdsProgressionDecision(
            localPercentage = 0.60f,
            localUpdatedAtMs = now - 10_000L,
            remote = remote(0.20f, updatedAt = earlier),
            playbackSessionActive = false,
        )

        assertEquals(OpdsProgressionDecision.PUSH, decision)
    }

    @Test
    fun the_book_that_is_playing_is_never_jumped_to_a_newer_remote_point() {
        val decision = opdsProgressionDecision(
            localPercentage = 0.20f,
            localUpdatedAtMs = now - 30_000L,
            remote = remote(0.60f, updatedAt = now - 5_000L),
            playbackSessionActive = true,
        )

        assertEquals(OpdsProgressionDecision.NONE, decision)
    }

    @Test
    fun a_recently_read_book_still_pulls_because_the_cache_write_cannot_move_an_open_reader() {
        val decision = opdsProgressionDecision(
            localPercentage = 0.20f,
            localUpdatedAtMs = now - 30_000L,
            remote = remote(0.60f, updatedAt = now - 5_000L),
            playbackSessionActive = false,
        )

        assertEquals(OpdsProgressionDecision.PULL, decision)
    }

    @Test
    fun a_disagreement_between_two_recent_writes_is_left_for_the_open_time_prompt() {
        val decision = opdsProgressionDecision(
            localPercentage = 0.60f,
            localUpdatedAtMs = earlier,
            remote = remote(0.20f, updatedAt = earlier + 60_000L),
            playbackSessionActive = false,
        )

        assertEquals(OpdsProgressionDecision.NONE, decision)
    }

    @Test
    fun matching_progress_is_left_alone() {
        val decision = opdsProgressionDecision(
            localPercentage = 0.60f,
            localUpdatedAtMs = earlier,
            remote = remote(0.601f, updatedAt = now - 5_000L),
            playbackSessionActive = false,
        )

        assertEquals(OpdsProgressionDecision.NONE, decision)
    }

    @Test
    fun a_push_is_not_blocked_by_an_active_playback_session() {
        val decision = opdsProgressionDecision(
            localPercentage = 0.60f,
            localUpdatedAtMs = now - 1_000L,
            remote = remote(0.20f, updatedAt = earlier),
            playbackSessionActive = true,
        )

        assertEquals(OpdsProgressionDecision.PUSH, decision)
    }

    private fun remote(percentage: Float, updatedAt: Long) = SyncSnapshot(
        percentage = percentage,
        source = BookSource.OPDS.displayName,
        updatedAt = updatedAt,
    )
}
