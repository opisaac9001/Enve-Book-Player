package com.enve.app.playback.clips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipSegmentsTest {
    private val tracks = listOf(
        ClipSourceTrack("file:///a.mp3", 60_000L),
        ClipSourceTrack("file:///b.mp3", 60_000L),
        ClipSourceTrack("file:///c.mp3", 60_000L),
    )

    @Test
    fun unicodeShareNamesFitAndroidFilesystems() {
        val name = clipShareFilename("本".repeat(82) + "\uD83D\uDCD6", "Chapter 1")
        assertTrue(name.toByteArray().size <= 255)
        assertEquals("本".repeat(82) + "\uD83D\uDCD6.m4a", name)
        assertEquals("本".repeat(83) + ".m4a", clipShareFilename("本".repeat(83) + "\uD83D\uDCD6", ""))
        assertEquals("a".repeat(100) + ".m4a", clipShareFilename("a".repeat(120), ""))
    }

    @Test
    fun clipInsideOneTrack() {
        assertEquals(
            listOf(ClipSegment("file:///b.mp3", 10_000L, 20_000L)),
            clipSegments(tracks, 70_000L, 80_000L),
        )
    }

    @Test
    fun clipAcrossTrackBoundaries() {
        assertEquals(
            listOf(
                ClipSegment("file:///a.mp3", 50_000L, 60_000L),
                ClipSegment("file:///b.mp3", 0L, 60_000L),
                ClipSegment("file:///c.mp3", 0L, 5_000L),
            ),
            clipSegments(tracks, 50_000L, 125_000L),
        )
    }

    @Test
    fun clipPastEndOfBookIsEmpty() {
        assertTrue(clipSegments(tracks, 180_000L, 190_000L).isEmpty())
    }
}
