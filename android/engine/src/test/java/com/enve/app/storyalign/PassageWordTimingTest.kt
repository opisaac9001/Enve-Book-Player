package com.enve.app.storyalign

import com.enve.app.playback.PlaybackState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PassageWordTimingTest {
    private val text = "Mara walked along the wooden pier."
    private val mara = PassageWordTiming(0, 4, 10.0, 10.3)
    private val walked = PassageWordTiming(5, 6, 10.4, 10.8)
    private val pier = PassageWordTiming(29, 4, 11.5, 11.9)

    @Test
    fun onlyOrderedPrintedWordsQualify() {
        assertEquals(listOf(mara, walked, pier), PassageWordTiming.validated(listOf(mara, walked, pier), text, 9.9, 12.0))
        assertTrue(PassageWordTiming.validated(listOf(PassageWordTiming(0, 2, 10.0, 10.2)), text, 9.9, 12.0).isEmpty())
        assertTrue(PassageWordTiming.validated(listOf(walked, mara), text, 9.9, 12.0).isEmpty())
        assertTrue(PassageWordTiming.validated(listOf(mara, walked.copy(start = 10.1)), text, 9.9, 12.0).isEmpty())
        assertTrue(PassageWordTiming.validated(listOf(mara.copy(end = mara.start)), text, 9.9, 12.0).isEmpty())
        assertTrue(PassageWordTiming.validated(listOf(PassageWordTiming(29, 40, 11.5, 11.9)), text, 9.9, 12.0).isEmpty())
    }

    @Test
    fun wordsAreClippedToATrimmedSentenceEnd() {
        assertEquals(listOf(mara, walked.copy(end = 10.6)), PassageWordTiming.validated(listOf(mara, walked, pier), text, 9.9, 10.6))
    }

    @Test
    fun shortGapsHoldTheSpokenWordButSilenceClearsIt() {
        val mapping = PassageMapping(0, "chapter.xhtml", text, "Before it.", "After it.", 0.0, 9.9, 12.0, listOf(mara, walked, pier))
        assertNull(mapping.wordAt(9.95))
        assertEquals(mara, mapping.wordAt(10.1))
        assertEquals(mara, mapping.wordAt(10.35))
        assertEquals(walked, mapping.wordAt(10.5))
        assertNull(mapping.wordAt(11.0))
        assertEquals(pier, mapping.wordAt(11.7))
        assertNull(mapping.wordAt(11.95))
    }

    @Test
    fun wordQuotesCarryTheirInSentenceContext() {
        val mapping = PassageMapping(0, "chapter.xhtml", text, "Before it.", "After it.", 0.0, 9.9, 12.0, listOf(mara, walked, pier))
        assertEquals(PassageQuote("pier", "Mara walked along the wooden ", "."), mapping.quote(pier))
        assertEquals(PassageQuote("Mara", "Before it.", " walked along the wooden pier."), mapping.quote(mara))
        assertEquals(PassageQuote("pier", "Mara walked along the wooden ", "After it."), mapping.copy(text = "Mara walked along the wooden pier").quote(pier))
    }

    @Test
    fun liveClockAdvancesBetweenPositionUpdatesOnlyWhilePlaying() {
        var now = 1_000L
        val clock = PassageClock { now }
        val playing = PlaybackState(isPlaying = true, currentPositionMs = 5_000, playbackSpeed = 1.5f)
        assertEquals(5.0, clock.seconds(playing), 1e-9)
        now += 200
        assertEquals(5.3, clock.seconds(playing), 1e-9)
        now += 1_000
        assertEquals(5.6, clock.seconds(playing), 1e-9)
        assertEquals(5.0, clock.seconds(playing.copy(isPlaying = false)), 1e-9)
        assertEquals(5.0, clock.seconds(playing.copy(isBuffering = true)), 1e-9)
        assertEquals(42.0, clock.seconds(playing.copy(currentPositionMs = 42_000)), 1e-9)
        now += 100
        assertEquals(42.15, clock.seconds(playing.copy(currentPositionMs = 42_000)), 1e-9)
    }
}
