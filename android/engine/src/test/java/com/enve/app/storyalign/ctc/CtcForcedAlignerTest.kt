package com.enve.app.storyalign.ctc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CtcForcedAlignerTest {
    @Test
    fun repeatedLettersRequireASeparatingBlank() {
        val scores = emissions(listOf(0, 1, 0, 1, 0))
        val timing = CtcForcedAligner.align(scores, intArrayOf(1, 1))!!
        assertEquals(1, timing[0].startFrame)
        assertEquals(3, timing[1].startFrame)
        assertNull(CtcForcedAligner.align(emissions(listOf(1, 1)), intArrayOf(1, 1)))
    }

    @Test
    fun fullCharacterPeaksAreRetainedAtBothBoundaries() {
        val timing = CtcForcedAligner.align(emissions(listOf(0, 1, 1, 1, 0, 2, 2, 2, 0)), intArrayOf(1, 2))!!
        assertEquals(1, timing.first().startFrame)
        assertEquals(4, timing.first().endFrame)
        assertEquals(5, timing.last().startFrame)
        assertEquals(8, timing.last().endFrame)
    }

    @Test
    fun unmatchedPrefixAndSuffixDoNotStretchTheReference() {
        val timing = CtcForcedAligner.align(emissions(listOf(2, 2, 0, 1, 0, 2, 0, 1, 2)), intArrayOf(1, 2, 1))!!
        assertEquals(3, timing.first().startFrame)
        assertEquals(8, timing.last().endFrame)
    }

    @Test
    fun impossibleAcousticsHaveNoPath() {
        val values = floatArrayOf(0f, Float.NEGATIVE_INFINITY, Float.NEGATIVE_INFINITY)
        assertNull(CtcForcedAligner.align(CtcEmissions(values, 1, 3, 0, 0.02), intArrayOf(1)))
    }

    @Test
    fun blankOnlyAudioDoesNotCreateConfidentWords() {
        val timing = CtcForcedAligner.align(emissions(List(20) { 0 }), intArrayOf(1, 2))!!
        assertTrue(timing.all { it.logProbability < -5 })
    }

    @Test(expected = IllegalArgumentException::class)
    fun trellisIsBoundedBeforeAllocation() {
        CtcForcedAligner.align(emissions(List(10_000) { 0 }), IntArray(1_000) { 1 })
    }

    @Test
    fun spaceProbabilityIsPreservedAsBlank() {
        val values = floatArrayOf(kotlin.math.ln(0.2).toFloat(), kotlin.math.ln(0.3).toFloat(), kotlin.math.ln(0.5).toFloat())
        CtcForcedAligner.foldSpaceIntoBlank(values, 3, 2, 0)
        assertEquals(kotlin.math.ln(0.7), values[2].toDouble(), 0.00001)
        assertEquals(Float.NEGATIVE_INFINITY, values[0])
    }

    @Test
    fun cancellationIsCheckedDuringAlignment() {
        var calls = 0
        val result = CtcForcedAligner.align(emissions(List(100) { if (it % 3 == 0) 1 else 0 }), intArrayOf(1)) { calls++ }
        assertNotNull(result)
        assertTrue(calls > 0)
    }

    private fun emissions(best: List<Int>): CtcEmissions {
        val values = FloatArray(best.size * 3) { -12f }
        best.forEachIndexed { frame, token -> values[frame * 3 + token] = -0.01f }
        return CtcEmissions(values, best.size, 3, 0, 0.02)
    }
}
