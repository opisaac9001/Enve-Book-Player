package com.enve.app.storyalign.align

import com.enve.app.storyalign.epub.EpubManifestItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AlignmentQualityTest {

    private val file = AudioFile(0, 0.0, FILE_SECONDS, "storyalign/Audio/0000.m4a")
    private val durations = mapOf(0 to FILE_SECONDS)

    @Test fun steadyAlignmentIsUsable() {
        val quality = assess(steadyChapter()).quality

        assertTrue("defects=${quality.defects}", quality.isUsable)
        assertEquals(10, quality.unitCount)
        assertEquals(1.0, quality.purity, 1e-9)
        assertEquals(1.0, quality.monotonicity, 1e-9)
        assertEquals(1.0, quality.confidence!!, 1e-9)
        assertTrue("coverage=${quality.coverage}", quality.coverage >= 0.85)
        assertTrue("largestGap=${quality.largestGap}", quality.largestGap <= 0.05)
    }

    @Test fun unevenPacingScoresLowerThanSteadyPacing() {
        val lurching = chapter(
            (0 until 10).map { id ->
                val start = id * 10.0
                val end = start + if (id % 2 == 0) 1.0 else 8.0
                alignedSentence(id, start, end)
            },
        )
        val uneven = assess(lurching).quality
        val steady = assess(steadyChapter()).quality

        assertTrue("defects=${uneven.defects}", uneven.isUsable)
        assertTrue(uneven.timingConsistency < steady.timingConsistency)
    }

    @Test fun malformedTimingsMakeAnAlignmentUnusable() {
        val broken = chapter(
            listOf(
                alignedSentence(0, 0.0, 9.0),
                alignedSentence(1, 10.0, 19.0),
                alignedSentence(2, 20.0, 29.0),
                alignedSentence(3, Double.NaN, 39.0),
                alignedSentence(4, 40.0, Double.POSITIVE_INFINITY),
                alignedSentence(5, 50.0, 49.0),
                alignedSentence(6, -5.0, 69.0),
                alignedSentence(7, 70.0, FILE_SECONDS + 500.0),
                alignedSentence(8, 80.0, 80.0),
                alignedSentence(9, 90.0, 90.0),
            ),
        )
        val quality = assess(broken).quality

        assertFalse(quality.isUsable)
        assertTrue(quality.defects.contains(AlignmentDefect.MALFORMED_UNITS))
        assertTrue("purity=${quality.purity}", quality.purity < 0.5)
    }

    @Test fun contradictoryTimingsMakeAnAlignmentUnusable() {
        val backwards = chapter(
            (0 until 10).map { id ->
                val start = if (id == 0) 0.0 else (10 - id) * 10.0
                alignedSentence(id, start, start + 9.0)
            },
        )
        val quality = assess(backwards).quality

        assertFalse(quality.isUsable)
        assertTrue(quality.defects.contains(AlignmentDefect.NOT_MONOTONIC))
    }

    @Test fun alignmentConfinedToOneSpotIsUnusable() {
        val clustered = chapter(
            (0 until 3).map { id -> alignedSentence(id, 50.0 + id * 0.4, 50.3 + id * 0.4) },
        )
        val quality = assess(clustered).quality

        assertFalse(quality.isUsable)
        assertTrue(quality.defects.contains(AlignmentDefect.DEGENERATE_SPAN))
    }

    @Test fun sparseRunIsRefusedAgainstADenseOne() {
        val sparse = chapter(
            listOf(
                alignedSentence(0, 0.0, 9.0),
                alignedSentence(1, 10.0, 19.0),
                alignedSentence(8, 80.0, 89.0),
                alignedSentence(9, 90.0, 99.0),
            ),
        )
        val decision = AlignmentQualityEvaluator.decide(assess(sparse), assess(steadyChapter()).quality)

        assertFalse(decision.accepted)
        assertEquals(AlignmentRejection.INFERIOR_CANDIDATE, decision.rejection)
        assertTrue(decision.explanation.isNotBlank())
    }

    @Test fun denseRunReplacesASparseOne() {
        val sparse = chapter(
            listOf(
                alignedSentence(0, 0.0, 9.0),
                alignedSentence(1, 10.0, 19.0),
                alignedSentence(8, 80.0, 89.0),
                alignedSentence(9, 90.0, 99.0),
            ),
        )
        val decision = AlignmentQualityEvaluator.decide(assess(steadyChapter()), assess(sparse).quality)

        assertTrue(decision.explanation, decision.accepted)
    }

    @Test fun anyUsableRunIsAcceptedWhenNothingIsStored() {
        assertTrue(AlignmentQualityEvaluator.decide(assess(steadyChapter()), null).accepted)
    }

    @Test fun unusableRunCannotReplaceAStoredAlignment() {
        val decision = AlignmentQualityEvaluator.decide(
            AlignmentQualityEvaluator.Assessment(
                emptyList(),
                quality(unitCount = 1, defects = listOf(AlignmentDefect.TOO_FEW_UNITS)),
            ),
            quality(),
        )

        assertFalse(decision.accepted)
        assertEquals(AlignmentRejection.INVALID_CANDIDATE, decision.rejection)
    }

    @Test fun runThatTradesOneMeasurementForAnotherIsAccepted() {
        val decision = AlignmentQualityEvaluator.decide(
            AlignmentQualityEvaluator.Assessment(
                emptyList(),
                quality(largestGap = 0.30, confidence = 1.0),
            ),
            quality(largestGap = 0.05, confidence = 0.40),
        )

        assertTrue(decision.explanation, decision.accepted)
    }

    @Test fun runIsAcceptedWhenTheStoredAlignmentIsItselfUnusable() {
        val decision = AlignmentQualityEvaluator.decide(
            assess(steadyChapter()),
            quality(defects = listOf(AlignmentDefect.NOT_MONOTONIC)),
        )

        assertTrue(decision.accepted)
    }

    private fun assess(chapter: AlignedChapter) =
        AlignmentQualityEvaluator.assess(listOf(chapter), durations)

    private fun steadyChapter(): AlignedChapter =
        chapter((0 until 10).map { id -> alignedSentence(id, id * 10.0, id * 10.0 + 9.0) })

    private fun chapter(aligned: List<AlignedSentence>): AlignedChapter = AlignedChapter(
        manifestItem = EpubManifestItem(
            id = "c1",
            href = "c1.xhtml",
            mediaType = "application/xhtml+xml",
            properties = null,
            spineItemIndex = 0,
            text = null,
            hasScript = false,
            xhtmlSentences = List(10) { SENTENCE },
            name = "Chapter One",
            xhtml = null,
        ),
        alignedSentences = aligned,
    )

    private fun alignedSentence(id: Int, start: Double, end: Double): AlignedSentence = AlignedSentence(
        xhtmlSentence = SENTENCE,
        sentenceId = id,
        sentenceRange = SentenceRange(id, start, end, file, emptyList()),
        matchType = SentenceMatchType.EXACT,
    )

    private fun quality(
        unitCount: Int = 10,
        coverage: Double = 0.90,
        largestGap: Double = 0.05,
        monotonicity: Double = 1.0,
        timingConsistency: Double = 1.0,
        purity: Double = 1.0,
        confidence: Double? = 1.0,
        defects: List<AlignmentDefect> = emptyList(),
    ) = AlignmentQuality(
        unitCount = unitCount,
        coverage = coverage,
        largestGap = largestGap,
        monotonicity = monotonicity,
        timingConsistency = timingConsistency,
        purity = purity,
        confidence = confidence,
        defects = defects,
    )

    private companion object {
        const val FILE_SECONDS = 100.0
        const val SENTENCE = "the narrator reads another plain line of prose"
    }
}
