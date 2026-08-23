package com.enve.app.readium

import com.enve.app.playback.cumulativeTrackOffsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadAloudTimelineTest {

    @Test
    fun pageFlipDelayTracksVisibleSentenceFractionAndPlaybackSpeed() {
        assertEquals(
            3_000L,
            readAloudPageFlipDelayMs(
                clipDurationMs = 8_000L,
                elapsedClipMs = 0L,
                visibleRatio = 0.5,
                playbackSpeed = 1f,
            ),
        )
        assertEquals(
            1_000L,
            readAloudPageFlipDelayMs(
                clipDurationMs = 8_000L,
                elapsedClipMs = 0L,
                visibleRatio = 0.5,
                playbackSpeed = 2f,
            ),
        )
    }

    @Test
    fun pageFlipDelayNeverSchedulesBeforeNow() {
        assertEquals(
            0L,
            readAloudPageFlipDelayMs(
                clipDurationMs = 500L,
                elapsedClipMs = 0L,
                visibleRatio = 0.25,
                playbackSpeed = 3f,
            ),
        )
    }

    @Test
    fun pageFlipDelayAccountsForElapsedClipTimeWhenRescheduled() {
        assertEquals(
            1_000L,
            readAloudPageFlipDelayMs(
                clipDurationMs = 8_000L,
                elapsedClipMs = 2_000L,
                visibleRatio = 0.5,
                playbackSpeed = 1f,
            ),
        )
    }

    @Test
    fun readAloudUsesTheSameTrackOffsetsAsNormalPlayback() {
        val offsets = cumulativeTrackOffsets(listOf(1_000L, 2_500L, 3_250L))

        assertEquals(listOf(0L, 1_000L, 3_500L), offsets)
    }

    @Test
    fun rawExternalTimelineWinsOverCompressedOverlayDuration() {
        val position = resolveReadAloudAbsoluteAudioPosition(
            externalWindowStartMs = 3_600_000L,
            playerPositionMs = 900_000L,
            overlayChapterStartMs = 2_800_000L,
            overlayElapsedBeforeClipMs = 500_000L,
            clipBeginMs = 880_000L,
            clipDurationMs = 30_000L,
        )

        assertEquals(4_500_000L, position)
    }

    @Test
    fun overlayTimelineRemainsFallbackWithoutExternalTracks() {
        val position = resolveReadAloudAbsoluteAudioPosition(
            externalWindowStartMs = null,
            playerPositionMs = 900_000L,
            overlayChapterStartMs = 2_800_000L,
            overlayElapsedBeforeClipMs = 500_000L,
            clipBeginMs = 880_000L,
            clipDurationMs = 30_000L,
        )

        assertEquals(3_320_000L, position)
    }

    @Test
    fun storytellerReadAloudNamesMapToNormalM4bChapterOrder() {
        assertEquals("00001-00001", storytellerReadAloudAudioStem("00000-00001.mp4"))
        assertEquals("00001-00022", storytellerReadAloudAudioStem("00021-00001.mp4"))
        assertEquals(null, storytellerReadAloudAudioStem("chapter-22.mp4"))
    }

    @Test
    fun storytellerReadAloudAliasWinsOverCollidingNormalFilename() {
        val exactKeyToIndex = mapOf(
            "00000-00001.mp4" to 0,
            "00001-00001.mp4" to 1,
        )
        val readAloudStemToIndex = mapOf(
            "00001-00001" to 0,
            "00001-00002" to 1,
        )

        assertEquals(
            0,
            resolveExternalAudioWindowIndex(
                "Audio/00001-00001.mp3",
                exactKeyToIndex,
                readAloudStemToIndex,
            ),
        )
        assertEquals(
            1,
            resolveExternalAudioWindowIndex(
                "Audio/00001-00002.mp3",
                exactKeyToIndex,
                readAloudStemToIndex,
            ),
        )
    }

    @Test
    fun externalAudioChapterSearchExpandsFromTheKnownWindow() {
        assertEquals(
            listOf(3, 2, 4, 1, 5, 0, 6),
            externalAudioChapterSearchIndices(chapterCount = 7, windowIndex = 3),
        )
    }

    @Test
    fun externalAudioChapterSearchClampsAndCoversEveryChapterOnce() {
        val indices = externalAudioChapterSearchIndices(chapterCount = 5, windowIndex = 20)

        assertEquals(listOf(4, 3, 2, 1, 0), indices)
        assertEquals((0 until 5).toSet(), indices.toSet())
        assertEquals(5, indices.size)
    }

    @Test
    fun syncOffsetMovesHighlightAheadAndBehindPlayback() {
        assertEquals(1_250L, readAloudHighlightPositionMs(1_000L, 250L))
        assertEquals(750L, readAloudHighlightPositionMs(1_000L, -250L))
    }

    @Test
    fun negativeSyncOffsetClampsHighlightToBookStart() {
        assertEquals(0L, readAloudHighlightPositionMs(100L, -250L))
    }

    @Test
    fun positiveOffsetHighlightDoesNotSeekAudioForward() {
        assertFalse(shouldCorrectReadAloudPosition(900L, 1_150L, 1_000L))
        assertTrue(shouldCorrectReadAloudPosition(500L, 750L, 1_000L))
    }

    @Test
    fun forwardReconciliationSkipsPastSkippableClips() {
        val clips = listOf(
            clip(beginMs = 0L),
            clip(beginMs = 1_000L, skippable = true),
            clip(beginMs = 2_000L, skippable = true),
            clip(beginMs = 3_000L),
        )

        assertEquals(3, resolveReadAloudForwardIndex(clips, 0, 1, skipSkippableClips = true))
        assertEquals(1, resolveReadAloudForwardIndex(clips, 0, 1, skipSkippableClips = false))
        assertEquals(1, resolveReadAloudForwardIndex(clips, 3, 1, skipSkippableClips = true))
    }

    @Test
    fun forwardReconciliationReturnsNullForSkippableChapterTail() {
        val clips = listOf(
            clip(beginMs = 0L),
            clip(beginMs = 1_000L, skippable = true),
        )

        assertEquals(null, resolveReadAloudForwardIndex(clips, 0, 1, skipSkippableClips = true))
    }

    private fun clip(beginMs: Long, skippable: Boolean = false) = SmilClip(
        textHref = "chapter.xhtml",
        textFragmentId = null,
        audioHref = "chapter.mp3",
        clipBeginMs = beginMs,
        clipEndMs = beginMs + 1_000L,
        skippable = skippable,
    )
}
