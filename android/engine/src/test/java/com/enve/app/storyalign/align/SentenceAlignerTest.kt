package com.enve.app.storyalign.align

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SentenceAlignerTest {
    private val aligner = SentenceAligner()
    private val audio = AudioFile(index = 0, startTime = 0.0, endTime = 1000.0, path = "a.m4a")

    private fun transcription(vararg tokens: String): Transcription {
        val words = tokens.mapIndexed { i, tok ->
            WordTimeStamp(tok, i * 0.5, i * 0.5 + 0.4, audio, i, -1, -1)
        }
        return TranscriptionBuilder.fromWords(words)
    }

    @Test fun alignsTwoSentencesToWordRanges() {
        val t = transcription(
            "the", "quick", "brown", "fox", "jumped", "over", "the", "lazy", "dog",
            "she", "sells", "sea", "shells",
        )
        val r = aligner.alignChapter(
            listOf("The quick brown fox jumped over the lazy dog.", "She sells sea shells."),
            t, 0,
        )
        assertEquals(2, r.alignedSentences.size)
        assertTrue(r.skippedSentences.isEmpty())

        val s0 = r.alignedSentences[0]
        assertEquals(0, s0.sentenceId)
        assertEquals(9, s0.sentenceRange.timeStamps.size)
        assertTrue(s0.sentenceRange.start in -0.001..0.001)

        val s1 = r.alignedSentences[1]
        assertEquals(1, s1.sentenceId)
        assertEquals(4, s1.sentenceRange.timeStamps.size)

        assertTrue(s1.sentenceRange.start >= s0.sentenceRange.end - 1e-9)
    }

    @Test fun interpolatesMissingMiddleSentence() {
        val t = transcription(
            "alpha", "beta", "gamma", "delta", "epsilon",
            "kappa", "lambda", "sigma", "theta", "omega",
        )
        val r = aligner.alignChapter(
            listOf(
                "Alpha beta gamma delta epsilon.",
                "Purple monkey dishwasher gadget here.",
                "Kappa lambda sigma theta omega.",
            ),
            t, 0,
        )
        assertEquals(3, r.alignedSentences.size)
        assertTrue(r.skippedSentences.isEmpty())

        val mid = r.alignedSentences[1]
        assertEquals(1, mid.sentenceId)
        assertEquals(SentenceMatchType.INTERPOLATED, mid.matchType)
        assertTrue(mid.sentenceRange.start >= r.alignedSentences[0].sentenceRange.end - 1e-9)
        assertTrue(mid.sentenceRange.end <= r.alignedSentences[2].sentenceRange.start + 1e-9)
    }

    @Test fun numberNormalizationBridgesDigitsAndSpokenForm() {

        val t = transcription("i", "have", "forty-two", "apples", "today")
        val r = aligner.alignChapter(listOf("I have 42 apples today."), t, 0)
        assertEquals(1, r.alignedSentences.size)
        assertEquals(5, r.alignedSentences[0].sentenceRange.timeStamps.size)
    }

    @Test fun romanNumeralBridgesToSpokenForm() {

        val t = transcription("chapter", "four", "begins", "now")
        val r = aligner.alignChapter(listOf("Chapter IV begins now."), t, 0)
        assertEquals(1, r.alignedSentences.size)
        assertEquals(4, r.alignedSentences[0].sentenceRange.timeStamps.size)
    }

    @Test fun skipsSentenceEntirelyAbsentAtEnd() {
        val t = transcription("hello", "there", "friend")
        val r = aligner.alignChapter(
            listOf("Hello there friend.", "Totally unrelated closing remark here."),
            t, 0,
        )
        assertEquals(1, r.alignedSentences.size)
        assertEquals(1, r.skippedSentences.size)
        assertEquals(1, r.skippedSentences[0].chapterSentenceId)
    }
}
