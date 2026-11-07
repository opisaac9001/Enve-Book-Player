package com.enve.app.storyalign

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PassageTextResolverTest {
    private val href = "OEBPS/Text/harbor.xhtml"
    private val texts = listOf(
        "The harbor was quiet before dawn.",
        "Mara walked along the wooden pier toward the lighthouse.",
        "Chapter Two",
        "She waited.",
        "The harbor was quiet before dawn.",
        "Gulls circled the masts as the tide turned.",
    )
    private val progressions = listOf(0.0, 0.1, 0.3, 0.35, 0.5, 0.8)
    private val sentences = texts.indices.map { PassageSentence(it, href, texts[it], progressions[it]) }

    private fun target(quote: String, before: String? = null, after: String? = null, progression: Double? = null) =
        PassageTextResolver.target(sentences, "Text/harbor.xhtml#p2", quote, before, after, progression)

    @Test
    fun selectedTextResolvesToItsSentence() {
        assertEquals(PassageTextResolver.Target.Found(sentences[1]), target("the wooden pier"))
        assertEquals(PassageTextResolver.Target.Found(sentences[5]), target("Gulls circled the masts as the tide turned."))
    }

    @Test
    fun repeatedTextDoesNotResolveWithoutEvidence() {
        assertEquals(PassageTextResolver.Target.Ambiguous, target("The harbor was quiet before dawn."))
        assertEquals(PassageTextResolver.Target.Ambiguous, target("The harbor was quiet", progression = 0.25))
        assertEquals(PassageTextResolver.Target.Ambiguous, target("ok"))
    }

    @Test
    fun surroundingTextOrClearProgressionPicksTheRepeatedSentence() {
        assertEquals(PassageTextResolver.Target.Found(sentences[4]), target("The harbor was quiet before dawn.", before = "Chapter Two\nShe waited. "))
        assertEquals(PassageTextResolver.Target.Found(sentences[0]), target("The harbor was quiet before dawn.", after = " Mara walked along"))
        assertEquals(PassageTextResolver.Target.Found(sentences[0]), target("The harbor was quiet before dawn.", progression = 0.05))
    }

    @Test
    fun selectionCrossingIntoTheNextSentenceStartsAtTheFirst() {
        assertEquals(PassageTextResolver.Target.Found(sentences[1]), target("lighthouse. Chapter Two"))
    }

    @Test
    fun textOutsideTheOriginalEpubIsMissing() {
        assertEquals(PassageTextResolver.Target.Missing, target("An entirely different paragraph"))
        assertEquals(PassageTextResolver.Target.Missing, PassageTextResolver.target(sentences, "other.xhtml", "the wooden pier", null, null, null))
    }

    @Test
    fun narratedNeighborsMarkAnUnspokenHeading() {
        val previous = mapping(1, 10.0, 14.0)
        val next = mapping(3, 14.8, 16.0)
        assertEquals(PassageTextResolution.NotSpoken(sentences[2]), PassageTextResolver.resolve(sentences[2], "Chapter Two", null, previous, next))
        assertEquals(PassageTextResolution.Unprepared(sentences[2]), PassageTextResolver.resolve(sentences[2], "Chapter Two", null, previous, mapping(3, 40.0, 42.0)))
        assertEquals(PassageTextResolution.Unprepared(sentences[5]), PassageTextResolver.resolve(sentences[5], "Gulls", null, next, null))
    }

    @Test
    fun selectionSeeksToItsFirstTimedWord() {
        val mapping = mapping(1, 10.0, 14.0, timedWords())
        assertEquals(11.5 - 0.16, PassageTextResolver.seekSeconds(mapping, "wooden pier toward"), 1e-9)
        assertEquals(11.2 - 0.16, PassageTextResolver.seekSeconds(mapping, "the wooden"), 1e-9)
        assertEquals(10.0, PassageTextResolver.seekSeconds(mapping, "Mara walked"), 1e-9)
        assertEquals(10.0, PassageTextResolver.seekSeconds(mapping, "the"), 1e-9)
        assertEquals(10.0, PassageTextResolver.seekSeconds(mapping(1, 10.0, 14.0), "wooden pier"), 1e-9)
        assertEquals(
            PassageTextResolution.Matched(mapping, 11.5 - 0.16),
            PassageTextResolver.resolve(sentences[1], "wooden pier", mapping, null, null),
        )
    }

    @Test
    fun hrefsMatchAcrossEncodingAndRelativeRoots() {
        assertTrue(PassageTextResolver.hrefMatches("OEBPS/Text/ch%201.xhtml#p3", "/oebps/text/ch 1.xhtml"))
        assertTrue(PassageTextResolver.hrefMatches("Text/ch1.xhtml", "OEBPS/Text/ch1.xhtml"))
        assertTrue(PassageTextResolver.hrefMatches("OEBPS/Text/a+b.xhtml", "Text/a+b.xhtml"))
        assertFalse(PassageTextResolver.hrefMatches("ch1.xhtml", "ch11.xhtml"))
        assertFalse(PassageTextResolver.hrefMatches("", "ch1.xhtml"))
    }

    private fun timedWords(): List<PassageWordTiming> {
        val text = texts[1]
        val starts = listOf(10.1, 10.4, 10.7, 11.2, 11.5, 11.9, 12.3, 12.7, 13.0)
        return com.enve.app.storyalign.ctc.CtcBookMatcher.lexicalWords(text).mapIndexed { index, range ->
            PassageWordTiming(range.first, range.last + 1 - range.first, starts[index], starts[index] + 0.25)
        }
    }

    private fun mapping(sentence: Int, start: Double, end: Double, words: List<PassageWordTiming> = emptyList()) =
        PassageMapping(sentence, href, texts[sentence], "", "", progressions[sentence], start, end, words)
}
