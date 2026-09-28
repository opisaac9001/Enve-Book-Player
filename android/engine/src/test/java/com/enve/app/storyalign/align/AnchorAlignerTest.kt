package com.enve.app.storyalign.align

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AnchorAlignerTest {

    private val aligner = AnchorAligner()

    private fun words(text: String): List<String> = text.trim().split(Regex("\\s+"))

    private fun matchedCount(matches: IntArray): Int = matches.count { it != AnchorAligner.UNMATCHED }

    private fun assertMonotonic(matches: IntArray) {
        var previous = -1
        matches.forEach { hypIndex ->
            if (hypIndex == AnchorAligner.UNMATCHED) return@forEach
            assertTrue("matches must not move backwards", hypIndex > previous)
            previous = hypIndex
        }
    }

    @Test
    fun identicalSequencesAlignPositionally() {
        val tokens = words("the quiet morning began before anyone else had stirred at all")

        val matches = aligner.align(tokens, tokens)

        assertEquals(tokens.size, matchedCount(matches))
        tokens.indices.forEach { assertEquals(it, matches[it]) }
    }

    @Test
    fun narrationInsertedInTheMiddleDoesNotStrandTheRemainingText() {
        val ref = words(
            "the quiet morning began before anyone stirred " +
                "she walked to the window and opened it wide " +
                "the street below was empty and the air was cold"
        )
        val hyp = words(
            "the quiet morning began before anyone stirred " +
                "chapter five read by a narrator for this recording of the novel " +
                "she walked to the window and opened it wide " +
                "the street below was empty and the air was cold"
        )

        val matches = aligner.align(ref, hyp)

        assertMonotonic(matches)
        assertEquals(ref.size, matchedCount(matches))
        assertEquals(hyp.size - 1, matches.last())
    }

    @Test
    fun transcriptDroppingWordsStillAlignsWhatSurvives() {
        val ref = words("she walked to the window and opened it wide before the storm arrived")
        val hyp = words("she walked to the window and opened it before the storm arrived")

        val matches = aligner.align(ref, hyp)

        assertMonotonic(matches)
        assertTrue(matchedCount(matches) >= ref.size - 2)
    }

    @Test
    fun misheardWordIsLeftUnmatchedWhileItsNeighboursStillAlign() {
        val ref = words("the street below was empty and the air was cold that evening")
        val hyp = words("the street below was empty and the heir was cold that evening")

        val matches = aligner.align(ref, hyp)

        assertMonotonic(matches)
        assertEquals(AnchorAligner.UNMATCHED, matches[ref.indexOf("air")])
        assertEquals(ref.size - 1, matchedCount(matches))
    }

    @Test
    fun unrelatedTextIsNotSubstitutedIntoAMatch() {
        val ref = words("purple monkey dishwasher gadget here")
        val hyp = words("kappa lambda sigma theta omega")

        val matches = aligner.align(ref, hyp)

        assertEquals(0, matchedCount(matches))
    }

    @Test
    fun repeatedPhrasesDoNotAnchorToTheWrongOccurrence() {
        val ref = words("he said hello there friend and then he said hello there stranger")
        val hyp = words("he said hello there friend and then he said hello there stranger")

        val matches = aligner.align(ref, hyp)

        assertMonotonic(matches)
        assertEquals(ref.size, matchedCount(matches))
    }

    @Test
    fun alignmentSurvivesNarrationThatDivergesThenRejoins() {
        val ref = words(
            "a quiet morning begins the reader turns a page the story reaches its end " +
                "and the lamp was put out for the night"
        )
        val hyp = words(
            "a quiet morning begins uh sorry let me start again the reader turns a page " +
                "the story reaches its end and the lamp was put out for the night"
        )

        val matches = aligner.align(ref, hyp)

        assertMonotonic(matches)
        assertEquals(ref.size, matchedCount(matches))
    }

    @Test
    fun emptyInputsProduceNoMatches() {
        assertEquals(0, aligner.align(emptyList(), words("anything at all")).size)
        assertEquals(0, matchedCount(aligner.align(words("anything at all"), emptyList())))
    }
}
