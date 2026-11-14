package com.enve.app.storyalign.ctc

import com.enve.app.storyalign.epub.EpubManifestItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CtcWordTimingTest {
    private val sentence = "The quiet traveller opened a wooden doorway and discovered a remarkably beautiful garden."

    @Test
    fun wordTimingsComeFromTheAlignedCharacters() {
        val matcher = CtcBookMatcher(listOf(chapter(sentence)), wordTimings = true)
        val match = matcher.match(emissions(matcher.text), 0.0, 0, 60.0) { }.single()
        val words = match.words
        assertEquals(13, words.size)
        assertEquals(listOf("The", "quiet", "traveller"), words.take(3).map { sentence.substring(it.location, it.location + it.length) })
        assertEquals(0.12, words.first().start, 1e-9)
        assertEquals(0.28, words.first().end, 1e-9)
        val garden = words.last()
        assertEquals(sentence.indexOf("garden"), garden.location)
        assertEquals(match.end, garden.end, 1e-9)
        assertTrue(words.zipWithNext().all { (a, b) -> b.location >= a.location + a.length && b.start >= a.end })
        assertTrue(words.all { it.start >= match.start && it.end <= match.end })
    }

    @Test
    fun sentenceMatchingWithoutWordTimingsIsUnchanged() {
        val plain = CtcBookMatcher(listOf(chapter(sentence)))
        val timed = CtcBookMatcher(listOf(chapter(sentence)), wordTimings = true)
        val expected = plain.match(emissions(plain.text), 0.0, 0, 60.0) { }.single()
        val actual = timed.match(emissions(timed.text), 0.0, 0, 60.0) { }.single()
        assertTrue(expected.words.isEmpty())
        assertEquals(expected, actual.copy(words = emptyList()))
    }

    @Test
    fun weaklyAlignedWordsAreLeftUntimed() {
        val matcher = CtcBookMatcher(listOf(chapter(sentence)), wordTimings = true)
        val normalized = matcher.text
        val weak = normalized.indexOf("wooden").let { it until it + 6 }.toSet()
        val words = matcher.match(emissions(normalized, weak), 0.0, 0, 60.0) { }.single().words
        val printed = words.map { sentence.substring(it.location, it.location + it.length) }
        assertFalse("wooden" in printed)
        assertTrue("a" in printed && "doorway" in printed)
    }

    @Test
    fun quotedDialogueKeepsWordTimings() {
        val line = "‘Come inside,’ said the quiet traveller beside the wooden doorway of the garden."
        val matcher = CtcBookMatcher(listOf(chapter(line)), wordTimings = true)
        val words = matcher.match(emissions(matcher.text), 0.0, 0, 60.0) { }.single().words
        assertEquals("Come", line.substring(words.first().location, words.first().location + words.first().length))
        assertEquals(13, words.size)
    }

    @Test
    fun lexicalWordsKeepContractionsAndHyphenatedWords() {
        val text = "Don’t stop, well-known ‘friend’ — now."
        val words = CtcBookMatcher.lexicalWords(text).map { text.substring(it.first, it.last + 1) }
        assertEquals(listOf("Don’t", "stop", "well-known", "friend", "now"), words)
    }

    private fun chapter(text: String) = EpubManifestItem("chapter", "chapter.xhtml", "application/xhtml+xml", null, 0, text, false, listOf(text), "Chapter", "<p>$text</p>")

    private fun emissions(normalized: String, weak: Set<Int> = emptySet()): CtcEmissions {
        val frames = ArrayList<Pair<Int, Float>>()
        repeat(12) { frames.add(28 to -0.01f) }
        normalized.forEachIndexed { index, character ->
            val label = if (character == '\'') 27 else character - 'a' + 1
            val score = if (index in weak) -5f else -0.01f
            frames.add(label to score)
            frames.add(label to score)
            frames.add(28 to -0.01f)
        }
        repeat(12) { frames.add(28 to -0.01f) }
        val values = FloatArray(frames.size * 29) { -15f }
        frames.forEachIndexed { frame, (label, score) -> values[frame * 29 + label] = score }
        return CtcEmissions(values, frames.size, 29, 28, 0.02)
    }
}
