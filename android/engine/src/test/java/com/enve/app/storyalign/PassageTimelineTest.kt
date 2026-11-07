package com.enve.app.storyalign

import com.enve.app.storyalign.ctc.CtcSentenceMatch
import com.enve.app.storyalign.ctc.CtcWordTiming
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PassageTimelineTest {
    private val href = "OEBPS/harbor.xhtml"
    private val texts = listOf(
        "The harbor was quiet before dawn.",
        "Mara walked along the wooden pier toward the lighthouse.",
        "Chapter Two",
        "She waited.",
        "Gulls circled the masts as the tide turned.",
        "The ferry horn sounded twice across the water.",
    )
    private val sentences = texts.indices.map { PassageSentence(it, href, texts[it], it / 6.0) }
    private val positions = texts.indices.map { it / 6.0 }

    private fun timeline(vararg durations: Double, windows: List<PassageWindow> = emptyList()): PassageTimeline {
        var offset = 0.0
        val tracks = durations.mapIndexed { index, duration -> PassageTrackSpan(index, offset, duration).also { offset += duration } }
        return PassageTimeline(tracks, sentences, positions, windows)
    }

    private fun match(sentence: Int, start: Double, end: Double, track: Int = 0, words: List<CtcWordTiming> = emptyList()) =
        CtcSentenceMatch(sentence, start, end, -0.1, track, words)

    @Test
    fun narratedSentenceAndWordUseTheBookTimeline() {
        val text = texts[1]
        val wooden = text.indexOf("wooden")
        val words = listOf(CtcWordTiming(wooden, 6, 11.0, 11.4), CtcWordTiming(wooden + 7, 4, 11.5, 11.8))
        val timeline = timeline(100.0, 100.0, windows = listOf(PassageWindow(1, 0, listOf(match(1, 10.0, 14.0, track = 1, words = words)))))
        val state = timeline.preparationState(111.2, null, false)
        assertEquals(110.0, state.mapping!!.start, 1e-9)
        assertEquals(114.0, state.mapping.end, 1e-9)
        assertEquals("wooden", state.mapping.quote(state.word!!).highlight)
        assertEquals(PassageTimeline.FOLLOWING, state.message)
        assertFalse(state.preparing)
        assertEquals("wooden", timeline.preparationState(111.45, null, false).let { it.mapping!!.quote(it.word!!).highlight })
        assertEquals("pier", timeline.preparationState(111.6, null, false).let { it.mapping!!.quote(it.word!!).highlight })
        assertNull(timeline.preparationState(112.5, null, false).word)
    }

    @Test
    fun shortPausesKeepTheSentenceAndLongSilenceIsAGap() {
        val timeline = timeline(300.0, windows = listOf(
            PassageWindow(0, 0, listOf(match(0, 10.0, 14.0), match(1, 15.0, 19.0))),
            PassageWindow(0, 1, listOf(match(3, 30.0, 33.0))),
        ))
        assertEquals(PassageAudioResolution.Pause(timeline.preparationState(12.0, null, false).mapping!!), timeline.resolve(14.5))
        assertEquals(PassageAudioResolution.Gap, timeline.resolve(25.0))
        val gap = timeline.preparationState(25.0, null, false)
        assertNull(gap.mapping)
        assertFalse(gap.preparing || gap.retryable)
    }

    @Test
    fun failedAnalysisOffersRetryAndRetryQueuesTheWindowAgain() {
        val timeline = timeline(300.0)
        timeline.beginAnalysis(0, 1)
        assertEquals("Matching the narrated passage…", timeline.preparationState(45.0, null, false).message)
        timeline.fail(0, 1)
        timeline.beginAnalysis(0, 2)
        timeline.record(PassageWindow(0, 2, emptyList())) {}
        val failed = timeline.preparationState(45.0, null, true)
        assertEquals("Couldn't analyze this part of the audiobook.", failed.message)
        assertTrue(failed.retryable)
        assertFalse(failed.preparing || failed.cannotKeepUp)
        assertNotEquals(0 to 1, timeline.nextWindow(45.0, 120.0))
        timeline.retry(45.0)
        assertEquals(0 to 1, timeline.nextWindow(45.0, 120.0))
        val waiting = timeline.preparationState(45.0, null, false)
        assertTrue(waiting.preparing)
        assertFalse(waiting.retryable)
        assertTrue(timeline.windows().none { it.index == 2 })
    }

    @Test
    fun windowWithoutConfidentMatchOffersRetry() {
        val timeline = timeline(300.0, windows = listOf(PassageWindow(0, 1, emptyList()), PassageWindow(0, 2, emptyList())))
        val rejected = timeline.preparationState(45.0, null, false)
        assertEquals("No confident match for this part of the audiobook.", rejected.message)
        assertTrue(rejected.retryable)
        assertEquals(PassageAudioResolution.Unprepared(PassageWindowState.PENDING), timeline.resolve(75.0))
    }

    @Test
    fun pausedPreparationExplainsWhyAPendingPassageWaits() {
        val state = timeline(300.0).preparationState(45.0, "Preparation paused until more storage is available.", false)
        assertEquals("Preparation paused until more storage is available.", state.message)
        assertFalse(state.preparing)
    }

    @Test
    fun handoffSearchesOutwardFromTheInterpolatedSentence() {
        val timeline = timeline(600.0, windows = listOf(
            PassageWindow(0, 3, listOf(match(1, 100.0, 110.0))),
            PassageWindow(0, 10, listOf(match(5, 300.0, 310.0))),
        ))
        assertEquals(110.0 + 190.0 / 3, timeline.estimate(3), 1e-6)
        assertEquals(100.0, timeline.estimate(1), 1e-9)
        val generation = timeline.beginHandoff(sentences[3])
        assertTrue(timeline.hasHandoff())
        assertEquals(0 to 5, timeline.takeHandoffWindow())
        assertTrue(timeline.handoffPending(generation))
        timeline.endHandoff(generation)
        assertFalse(timeline.handoffPending(generation))
        assertNull(timeline.takeHandoffWindow())
    }

    @Test
    fun handoffEndsWhenNoWindowIsLeftToAnalyze() {
        val timeline = timeline(60.0)
        val generation = timeline.beginHandoff(sentences[3])
        repeat(2) {
            val (track, index) = checkNotNull(timeline.takeHandoffWindow())
            timeline.beginAnalysis(track, index)
            timeline.record(PassageWindow(track, index, emptyList())) {}
        }
        assertFalse(timeline.handoffPending(generation))
        assertNull(timeline.takeHandoffWindow())
        assertFalse(timeline.hasHandoff())
    }

    @Test
    fun newerHandoffSupersedesTheOlderRequest() {
        val timeline = timeline(600.0)
        val first = timeline.beginHandoff(sentences[1])
        val second = timeline.beginHandoff(sentences[4])
        assertFalse(timeline.handoffPending(first))
        assertTrue(timeline.handoffPending(second))
        timeline.endHandoff(first)
        assertTrue(timeline.hasHandoff())
    }

    @Test
    fun selectedTextResolvesAgainstPreparedPassages() {
        val timeline = timeline(300.0, windows = listOf(PassageWindow(0, 0, listOf(match(1, 10.0, 14.0), match(3, 14.8, 16.0)))))
        val matched = timeline.resolveText("harbor.xhtml", "wooden pier", null, null, null)
        assertEquals(10.0, (matched as PassageTextResolution.Matched).seekSeconds, 1e-9)
        assertEquals(PassageTextResolution.NotSpoken(sentences[2]), timeline.resolveText("harbor.xhtml", "Chapter Two", null, null, null))
        assertEquals(PassageTextResolution.Unprepared(sentences[4]), timeline.resolveText("harbor.xhtml", "Gulls circled", null, null, null))
        assertEquals(PassageTextResolution.Unprepared(null), timeline.resolveText("harbor.xhtml", "not in this book", null, null, null))
    }

    @Test
    fun cachedWindowsOutsideTheCurrentLayoutAreIgnored() {
        val timeline = timeline(60.0, windows = listOf(PassageWindow(4, 0, listOf(match(1, 10.0, 14.0, track = 4)))))
        assertEquals(PassageAudioResolution.Unprepared(PassageWindowState.PENDING), timeline.resolve(12.0))
    }
}
