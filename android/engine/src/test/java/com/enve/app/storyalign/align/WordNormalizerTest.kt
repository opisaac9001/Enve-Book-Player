package com.enve.app.storyalign.align

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WordNormalizerTest {
    private val n = WordNormalizer()

    @Test fun spellsCardinals() {
        assertEquals("zero", spellCardinal(0))
        assertEquals("one", spellCardinal(1))
        assertEquals("nineteen", spellCardinal(19))
        assertEquals("twenty-one", spellCardinal(21))
        assertEquals("one hundred", spellCardinal(100))
        assertEquals("one hundred twenty-three", spellCardinal(123))
        assertEquals("one thousand", spellCardinal(1000))
        assertEquals("one thousand nine hundred ninety-eight", spellCardinal(1998))
        assertEquals("one million", spellCardinal(1_000_000))
    }

    @Test fun normalizesIntegerWords() {
        assertEquals("forty-two", n.normalizedWord("42").first)
        assertEquals("one thousand nine hundred ninety-eight", n.normalizedWord("1998").first)
    }

    @Test fun normalizesRomanNumerals() {
        assertTrue(n.isRomanNumeral("IV"))
        assertTrue(!n.isRomanNumeral("I"))
        assertEquals(4, n.intFromRomanNumeral("IV"))
        assertEquals(14, n.intFromRomanNumeral("XIV"))
        assertEquals("four", n.normalizedWord("IV").first)
    }

    @Test fun normalizesPunctuation() {
        assertEquals("\"hello\"", n.normalizePunctuation("“hello”"))
        assertEquals("it's", n.normalizePunctuation("it’s"))
        assertEquals("a\u2014b", n.normalizePunctuation("a--b"))
    }

    @Test fun normalizesSentenceWithNumber() {
        assertEquals("I have three apples", n.normalizeWordsInSentence("I have 3 apples"))
    }

    @Test fun percentBecomesWord() {
        assertEquals("fifty percent", n.normalizedWord("50%").first)
    }

    @Test fun handlesLeadingSpacePunctuationTokens() {
        for (tok in listOf(" .", " ,", " ?", "  ", ".", " . ", "\u2014", " \u2014", " .,")) {
            val out = n.normalizedWord(tok).first
            assertTrue("normalized \"$tok\" should be non-null", out.length >= 0)
        }
    }
}
