package com.enve.app.storyalign.ctc

import com.enve.app.storyalign.epub.EpubManifestItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CtcEmissionStitcherTest {
    @Test
    fun sentenceCrossingBothInferenceWindowsCanBeAlignedInTheStitchedInterval() {
        val sentence = "The quiet traveller opened a wooden doorway and discovered a remarkably beautiful garden."
        val item = EpubManifestItem("chapter", "chapter.xhtml", "application/xhtml+xml", null, 0, sentence, false, listOf(sentence), "Chapter", "<p>$sentence</p>")
        val matcher = CtcBookMatcher(listOf(item))
        val values = FloatArray(3_700 * 29) { if (it % 29 == 28) -0.01f else -15f }
        val letters = CtcBookMatcher.normalize(sentence)
        letters.forEachIndexed { index, letter ->
            val token = if (letter == '\'') 27 else letter - 'a' + 1
            val firstFrame = 1_000 + index * 1_000 / letters.length
            for (frame in firstFrame..firstFrame + 1) {
                values[frame * 29 + 28] = -15f
                values[frame * 29 + token] = -0.01f
            }
        }
        val previous = CtcEmissionWindow(CtcEmissions(values.copyOfRange(0, 1_900 * 29), 1_900, 29, 28, 0.02), 0.0, 38.0)
        for (overlap in listOf(12, 2)) {
            val startFrame = (38 - overlap) * 50
            val duration = (76 - overlap).toDouble()
            val current = CtcEmissionWindow(CtcEmissions(values.copyOfRange(startFrame * 29, (startFrame + 1_900) * 29), 1_900, 29, 28, 0.02), (38 - overlap).toDouble(), 38.0)
            assertTrue(matcher.match(previous.emissions, previous.start, 0, duration) { }.isEmpty())
            assertTrue(matcher.match(current.emissions, current.start, 0, duration) { }.isEmpty())
            val stitched = CtcEmissionStitcher.stitch(previous, current)
            val matches = matcher.match(stitched.emissions, stitched.start, 0, duration) { }
            assertEquals(1, matches.size)
            assertEquals(19.72, matches.single().start, 0.02)
            assertTrue(matches.single().end in 39.0..40.1)
            assertEquals((duration * 50).toInt(), stitched.emissions.frames)
        }
    }

    @Test
    fun overlapIsCutOnceAtItsMidpointWithoutShiftingTheClock() {
        val previous = CtcEmissionWindow(CtcEmissions(FloatArray(1_900 * 3) { -1f }, 1_900, 3, 0, 0.02), 100.0, 38.0)
        val current = CtcEmissionWindow(CtcEmissions(FloatArray(1_900 * 3) { -2f }, 1_900, 3, 0, 0.02), 126.0, 38.0)
        val stitched = CtcEmissionStitcher.stitch(previous, current)
        assertEquals(100.0, stitched.start, 0.0)
        assertEquals(64.0, stitched.duration, 0.0)
        assertEquals(-1f, stitched.emissions.values[1_599 * 3])
        assertEquals(-2f, stitched.emissions.values[1_600 * 3])
        assertEquals(3_200, stitched.emissions.frames)
        assertEquals(132.0, stitched.start + 1_600 * stitched.emissions.secondsPerFrame, 0.0)
    }

    @Test
    fun twoSecondOverlapPreservesSeamTimingWithinTheBoundedPair() {
        val previous = CtcEmissionWindow(CtcEmissions(FloatArray(1_900 * 3) { -1f }, 1_900, 3, 0, 0.02), 0.0, 38.0)
        val current = CtcEmissionWindow(CtcEmissions(FloatArray(1_900 * 3) { -2f }, 1_900, 3, 0, 0.02), 36.0, 38.0)
        val stitched = CtcEmissionStitcher.stitch(previous, current)
        assertEquals(74.0, stitched.duration, 0.0)
        assertEquals(3_700, stitched.emissions.frames)
        assertEquals(-1f, stitched.emissions.values[1_849 * 3])
        assertEquals(-2f, stitched.emissions.values[1_850 * 3])
        assertEquals(37.0, stitched.start + 1_850 * stitched.emissions.secondsPerFrame, 0.0)
    }

    @Test(expected = IllegalArgumentException::class)
    fun windowsFromDifferentFrameRatesCannotBeStitched() {
        CtcEmissionStitcher.stitch(
            CtcEmissionWindow(CtcEmissions(FloatArray(1_900 * 3), 1_900, 3, 0, 0.02), 0.0, 38.0),
            CtcEmissionWindow(CtcEmissions(FloatArray(950 * 3), 950, 3, 0, 0.04), 26.0, 38.0),
        )
    }
}
