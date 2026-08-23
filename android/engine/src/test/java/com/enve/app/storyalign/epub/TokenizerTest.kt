package com.enve.app.storyalign.epub

import com.enve.engine.storyalign.StoryAlignGranularity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TokenizerTest {
    private val t = Tokenizer()

    @Test fun emptyInputs() {
        assertEquals(emptyList<String>(), t.tokenizeWords(""))
        assertEquals(emptyList<String>(), t.tokenizeSentences(""))
        assertEquals(emptyList<String>(), t.tokenizePhrases(""))
    }

    @Test fun words_attachDelimiterToPrecedingToken() {

        assertEquals(listOf("a ", "b ", "c"), t.tokenizeWords("a b c"))
    }

    @Test fun words_commaIsSeparatorPeriodIsNot() {

        assertEquals(listOf("quick, ", "brown"), t.tokenizeWords("quick, brown"))
        assertEquals(listOf("Mr.Smith"), t.tokenizeWords("Mr.Smith"))
    }

    @Test fun sentences_splitOnTerminators() {
        assertEquals(3, t.tokenizeSentences("One. Two. Three.").size)
        val s = t.tokenizeSentences("Hello there. How are you?")
        assertEquals(2, s.size)
        assertTrue(s[0].contains("Hello there"))
    }

    @Test fun sentences_reconstructOriginal() {
        val text = "The quick brown fox. It jumped over the lazy dog."
        assertEquals(text, t.tokenizeSentences(text).joinToString("").trimEnd())
    }

    @Test fun phrases_splitOnInternalPunctuation() {
        val phrases = t.tokenizePhrases("First part, second part, and the final part here.")
        assertTrue(phrases.size >= 2)

        assertTrue(phrases.all { it.isNotBlank() })
    }

    @Test fun granularityHelper() {
        assertTrue(!StoryAlignGranularity.SENTENCE.useWordTokenizer)
        assertTrue(!StoryAlignGranularity.PHRASE.useWordTokenizer)
        assertTrue(StoryAlignGranularity.SEGMENT.useWordTokenizer)
        assertTrue(StoryAlignGranularity.GROUP.useWordTokenizer)
        assertTrue(StoryAlignGranularity.WORD.useWordTokenizer)
    }
}
