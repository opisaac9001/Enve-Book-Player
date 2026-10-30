package com.enve.app.storyalign.ctc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CtcSentenceSelectorTest {
    @Test
    fun nestedRangesCannotReplayTheSameAudio() {
        val result = CtcSentenceSelector.select(listOf(match(0, 0.0, 10.0), match(1, 2.0, 3.0), match(2, 4.0, 5.0)))
        assertEquals(listOf(1, 2), result.map { it.sentence })
    }

    @Test
    fun aLateOutlierDoesNotDiscardTheCorrectSuffix() {
        val result = CtcSentenceSelector.select((0 until 10).map { index ->
            val start = if (index == 3) 90.0 else index * 2.0
            match(index, start, start + 1.0)
        })
        assertEquals(listOf(0, 1, 2, 4, 5, 6, 7, 8, 9), result.map { it.sentence })
    }

    @Test
    fun smallOverlapsAreClippedWithoutCreatingNonpositiveDurations() {
        val result = CtcSentenceSelector.select(listOf(match(0, 0.0, 1.0), match(1, 0.8, 1.8), match(2, 1.7, 2.7)))
        assertEquals(3, result.size)
        assertEquals(0.8, result[0].end, 0.0)
        assertEquals(1.7, result[1].end, 0.0)
        assertTrue(result.all { it.end - it.start >= 0.04 })
        assertTrue(result.zipWithNext().all { (a, b) -> a.end <= b.start })
    }

    @Test
    fun increasingStartsDoNotPermitDecreasingEnds() {
        val result = CtcSentenceSelector.select(listOf(match(0, 0.0, 1.0), match(1, 0.5, 0.75)))
        assertEquals(1, result.size)
    }

    @Test
    fun audioFileBoundariesUseFileOrderInsteadOfLocalTimestampOrder() {
        val result = CtcSentenceSelector.select(listOf(match(0, 8.0, 10.0), match(1, 0.0, 1.0).copy(audioIndex = 1)))
        assertEquals(2, result.size)
        assertEquals(10.0, result.first().end, 0.0)
    }

    @Test
    fun bookSizedChainsRemainSupported() {
        val result = CtcSentenceSelector.select((0 until 17_000).map { match(it, it * 1.2, it * 1.2 + 1.0) })
        assertEquals(17_000, result.size)
    }

    private fun match(id: Int, start: Double, end: Double) = CtcSentenceMatch(id, start, end, -0.1, 0)
}
