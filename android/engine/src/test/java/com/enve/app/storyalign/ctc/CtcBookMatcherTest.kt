package com.enve.app.storyalign.ctc

import com.enve.app.storyalign.epub.EpubManifestItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CtcBookMatcherTest {
    private val sentence = "The quiet traveller opened a wooden doorway and discovered a remarkably beautiful garden."

    @Test
    fun oneForwardAnchorOutlierDoesNotDiscardTheCorrectSuffix() {
        val anchors = listOf(0, 12, 90, 36, 48, 60).mapIndexed { index, position ->
            CtcAnchor(position, index * 12, index * 30)
        }
        val chain = CtcBookMatcher.longestAnchorChain(anchors)
        assertEquals(listOf(0, 12, 36, 48, 60), chain.map { it.document })
        assertTrue(chain.zipWithNext().all { (a, b) -> b.document > a.document && b.query > a.query && b.frame > a.frame })
    }

    @Test
    fun mapsTheReferenceSentenceFromAcousticEvidence() {
        val matcher = CtcBookMatcher(listOf(chapter(sentence)))
        val result = matcher.match(emissions(sentence), 0.0, 0, 60.0) { }
        assertEquals(1, result.size)
        assertEquals(0, result.single().sentence)
        assertTrue(result.single().start >= 0)
        assertTrue(result.single().end > result.single().start)
    }

    @Test
    fun shortSentenceRemainsEligibleInsideAnAnchoredPassage() {
        val lines = listOf(sentence, "Go.", "Afterwards a distant bell rang softly across the valley beneath the mountains.")
        val text = lines.joinToString(" ")
        val item = chapter(text).copy(xhtmlSentences = lines)
        val matcher = CtcBookMatcher(listOf(item))
        val result = matcher.match(emissions(text), 0.0, 0, 120.0) { }
        assertTrue(result.any { it.sentence == 1 })
    }

    @Test
    fun unrelatedAndSilentAudioDoNotMatchTheBook() {
        val matcher = CtcBookMatcher(listOf(chapter(sentence)))
        assertTrue(matcher.match(emissions("Someone announced that the train would arrive on Thursday afternoon."), 0.0, 0, 60.0) { }.isEmpty())
        val silent = CtcEmissions(FloatArray(100 * 29) { if (it % 29 == 28) -0.01f else -15f }, 100, 29, 28, 0.02)
        assertTrue(matcher.match(silent, 0.0, 0, 60.0) { }.isEmpty())
    }

    @Test
    fun duplicatedPassagesDoNotCreateAmbiguousAnchors() {
        val matcher = CtcBookMatcher(listOf(chapter(sentence), chapter(sentence)))
        assertTrue(matcher.match(emissions(sentence), 0.0, 0, 60.0) { }.isEmpty())
    }

    @Test
    fun windowOffsetIsIncludedInAudioTimes() {
        val matcher = CtcBookMatcher(listOf(chapter(sentence)))
        val local = matcher.match(emissions(sentence), 0.0, 0, 120.0) { }.single()
        val later = matcher.match(emissions(sentence), 30.0, 0, 120.0) { }.single()
        assertEquals(30.0, later.end - local.end, 0.0001)
    }

    private fun chapter(text: String) = EpubManifestItem("chapter", "chapter.xhtml", "application/xhtml+xml", null, 0, text, false, listOf(text), "Chapter", "<p>$text</p>")

    private fun emissions(text: String): CtcEmissions {
        val labels = CtcBookMatcher.normalize(text).map { if (it == '\'') 27 else it - 'a' + 1 }
        val tokens = List(12) { 28 } + labels.flatMap { listOf(it, it, 28) } + List(12) { 28 }
        val values = FloatArray(tokens.size * 29) { -15f }
        tokens.forEachIndexed { frame, label -> values[frame * 29 + label] = -0.01f }
        return CtcEmissions(values, tokens.size, 29, 28, 0.02)
    }
}
