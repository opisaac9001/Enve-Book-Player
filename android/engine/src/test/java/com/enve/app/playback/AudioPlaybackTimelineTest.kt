package com.enve.app.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class AudioPlaybackTimelineTest {
    @Test
    fun singleTrackDoesNotUseMultiTrackOffsets() {
        val reliable = hasReliableMultiTrackTimeline(
            itemCount = 1,
            trackDurationsMs = emptyList(),
        )

        assertEquals(false, reliable)
    }

    @Test
    fun completeMultiTrackDurationsUseAbsoluteOffsets() {
        val reliable = hasReliableMultiTrackTimeline(
            itemCount = 3,
            trackDurationsMs = listOf(60_000L, 90_000L, 120_000L),
        )

        assertEquals(true, reliable)
    }

    @Test
    fun metadataDurationWinsOverTransientReceiverTimeline() {
        val duration = resolveTrackDurationMs(
            metadataDurationMs = 3_600_000L,
            timelineDurationMs = 10_000L,
            currentDurationMs = 10_000L,
            isCurrentItem = true,
        )

        assertEquals(3_600_000L, duration)
    }

    @Test
    fun receiverTimelineFillsMissingMetadataDuration() {
        val duration = resolveTrackDurationMs(
            metadataDurationMs = 0L,
            timelineDurationMs = 90_000L,
            currentDurationMs = 10_000L,
            isCurrentItem = true,
        )

        assertEquals(90_000L, duration)
    }

    @Test
    fun missingTrackOffsetsUseControllerPosition() {
        val position = resolveAbsolutePlaybackPosition(
            localPositionMs = 42_000L,
            currentIndex = 0,
            trackOffsetsMs = emptyList(),
        )

        assertEquals(42_000L, position)
    }

    @Test
    fun multiTrackAddsCurrentTrackOffset() {
        val position = resolveAbsolutePlaybackPosition(
            localPositionMs = 12_000L,
            currentIndex = 2,
            trackOffsetsMs = listOf(0L, 60_000L, 150_000L),
        )

        assertEquals(162_000L, position)
    }

    @Test
    fun durationlessQueueSeeksWithinCurrentTrack() {
        val target = resolveRelativeQueueSeek(
            durationsMs = listOf(0L, 0L, 0L),
            currentIndex = 1,
            currentPositionMs = 45_000L,
            deltaMs = 30_000L,
        )

        assertEquals(QueueSeekTarget(1, 75_000L), target)
    }

    @Test
    fun durationlessQueueNeverResolvesBackwardSeekToFinalTrack() {
        val target = resolveRelativeQueueSeek(
            durationsMs = listOf(0L, 0L, 0L),
            currentIndex = 1,
            currentPositionMs = 20_000L,
            deltaMs = -30_000L,
        )

        assertEquals(QueueSeekTarget(1, 0L), target)
    }

    @Test
    fun knownQueueCarriesForwardSeekIntoNextTrack() {
        val target = resolveRelativeQueueSeek(
            durationsMs = listOf(60_000L, 90_000L, 120_000L),
            currentIndex = 1,
            currentPositionMs = 80_000L,
            deltaMs = 30_000L,
        )

        assertEquals(QueueSeekTarget(2, 20_000L), target)
    }

    @Test
    fun knownQueueCarriesBackwardSeekIntoPreviousTrack() {
        val target = resolveRelativeQueueSeek(
            durationsMs = listOf(60_000L, 90_000L, 120_000L),
            currentIndex = 1,
            currentPositionMs = 10_000L,
            deltaMs = -30_000L,
        )

        assertEquals(QueueSeekTarget(0, 40_000L), target)
    }
}
