package com.enve.app.readium

import com.enve.core.data.model.AudioTrack
import com.enve.core.reader.MediaOverlayTimeline
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlayerReadAloudServiceTest {
    private val first = MediaOverlayTimeline.Clip("sentence", "Text/one.xhtml", "Audio/one.mp3", 1.0, 3.0)
    private val second = MediaOverlayTimeline.Clip("sentence", "Text/two.xhtml", "Audio/two.mp3", 2.0, 4.0)
    private val timeline = MediaOverlayTimeline(listOf(first, second), mapOf("Audio/one.mp3" to 10.0, "Audio/two.mp3" to 8.0))

    @Test
    fun preservesDeclaredAudioGapsBetweenFiles() {
        assertEquals(mapOf("Audio/one.mp3" to 0L, "Audio/two.mp3" to 10_000L),
            playerReadAloudOffsets(timeline, emptyList(), 18_000L))
    }

    @Test
    fun usesActualAudiobookTrackOrderAndDurations() {
        val tracks = listOf(
            AudioTrack(0, "two.mp3", durationMs = 9_000L),
            AudioTrack(1, "one.mp3", durationMs = 12_000L),
        )
        assertEquals(mapOf("Audio/one.mp3" to 9_000L, "Audio/two.mp3" to 0L),
            playerReadAloudOffsets(timeline, tracks, 21_000L))
    }

    @Test
    fun rejectsUnmatchedAudioWithDifferentDuration() {
        assertNull(playerReadAloudOffsets(timeline, listOf(AudioTrack(0, "other.m4b", durationMs = 50_000L)), 50_000L))
    }

    @Test
    fun unknownTrackDurationCannotProduceConfidentOffsets() {
        assertNull(playerReadAloudOffsets(timeline, listOf(
            AudioTrack(0, "one.mp3", durationMs = 0L),
            AudioTrack(1, "two.mp3", durationMs = 8_000L),
        ), 50_000L))
    }

    @Test
    fun activeSentenceUsesWholeBookTimeAcrossChapterGaps() {
        val document = PlayerReadAloudDocument(File("fixture.epub"), timeline,
            mapOf("Text/one.xhtml#sentence" to "First chapter.", "Text/two.xhtml#sentence" to "Second chapter."))
        val lines = document.lines()
        assertEquals(lines.first(), playerReadAloudActiveLine(lines, 0L))
        assertEquals(lines.first(), playerReadAloudActiveLine(lines, 11_000L))
        assertEquals(lines.last(), playerReadAloudActiveLine(lines, 12_000L))
        assertNull(playerReadAloudActiveLine(emptyList(), 0L))
    }

    @Test
    fun liftsSentenceSeekTimesOntoWholeBookTimeline() {
        val document = PlayerReadAloudDocument(File("fixture.epub"), timeline,
            mapOf("Text/one.xhtml#sentence" to "First chapter.", "Text/two.xhtml#sentence" to "Second chapter."))
        val lines = document.lines(durationMs = 18_000L)
        assertEquals(listOf(1_000L, 12_000L), lines.map { it.startMs })
        assertEquals(listOf(3_000L, 14_000L), lines.map { it.endMs })
        assertEquals(listOf(0, 1), lines.map { it.clipIndex })
        assertEquals(2, lines.map { it.id }.distinct().size)
    }

    @Test
    fun skipsMissingSentenceTextWithoutChangingClipIdentity() {
        val document = PlayerReadAloudDocument(File("fixture.epub"), timeline,
            mapOf("Text/two.xhtml#sentence" to "Second chapter."))
        assertEquals(1, document.lines().single().clipIndex)
        assertEquals(12_000L, document.lines().single().startMs)
    }

    @Test
    fun repeatedFragmentsHaveDistinctClipKeys() {
        val repeated = MediaOverlayTimeline(listOf(first, first.copy(clipBegin = 3.0, clipEnd = 5.0)))
        val document = PlayerReadAloudDocument(File("fixture.epub"), repeated,
            mapOf("Text/one.xhtml#sentence" to "Repeated sentence."))
        assertEquals(2, document.lines().map { it.id }.distinct().size)
    }

    @Test
    fun embeddedAudioIgnoresExternalAudiobookTrackDurations() {
        val document = PlayerReadAloudDocument(File("fixture.epub"), timeline,
            mapOf("Text/two.xhtml#sentence" to "Second chapter."), embeddedAudio = true)
        val tracks = listOf(AudioTrack(0, "one.mp3", durationMs = 60_000L),
            AudioTrack(1, "two.mp3", durationMs = 60_000L))
        assertEquals(12_000L, document.lines(tracks, 120_000L).single().startMs)
    }

    @Test
    fun mapsStorytellerSplitAudiobookNamesToEpubAudio() {
        val storyteller = MediaOverlayTimeline(listOf(
            first.copy(audioSrc = "Audio/00001-00001.m4a"),
            second.copy(audioSrc = "Audio/00001-00002.m4a"),
        ))
        val tracks = listOf(
            AudioTrack(0, "00000-00001.m4b", durationMs = 10_000L),
            AudioTrack(1, "00001-00001.m4b", durationMs = 20_000L),
        )
        assertEquals(mapOf("Audio/00001-00001.m4a" to 0L, "Audio/00001-00002.m4a" to 10_000L),
            playerReadAloudOffsets(storyteller, tracks, 30_000L))
    }
}
