package com.enve.app.ui.screens.reader

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Locale

class ReaderLookupTest {
    @Test
    fun translationNormalisesWhitespaceAndRespectsTheLengthLimit() {
        assertEquals("Il pleut sur la ville", ReaderLookup.translationText("  Il pleut\n\tsur la   ville "))
        assertNull(ReaderLookup.translationText(" \n "))
        assertEquals(
            ReaderLookup.MAX_TRANSLATION_CHARS,
            ReaderLookup.translationText("a".repeat(ReaderLookup.MAX_TRANSLATION_CHARS))?.length,
        )
        assertNull(ReaderLookup.translationText("a".repeat(ReaderLookup.MAX_TRANSLATION_CHARS + 1)))
    }

    @Test
    fun wikipediaQueriesStripSurroundingPunctuationAndRejectPassages() {
        assertEquals("Heathcliff", ReaderLookup.wikipediaQuery("“Heathcliff,”"))
        assertEquals("Wuthering Heights", ReaderLookup.wikipediaQuery("\n(Wuthering   Heights)…"))
        assertEquals("rock-and-roll", ReaderLookup.wikipediaQuery("rock-and-roll."))
        assertNull(ReaderLookup.wikipediaQuery("…—!"))
        assertNull(ReaderLookup.wikipediaQuery("one two three four five six seven eight nine ten eleven"))
        assertNull(ReaderLookup.wikipediaQuery("x".repeat(ReaderLookup.MAX_WIKIPEDIA_CHARS + 1)))
    }

    @Test
    fun wikipediaUrlEncodesTheQueryForTheReadersLanguage() {
        val url = ReaderLookup.wikipediaUrl("Jane Eyre & Co/1?", Locale.FRANCE).toHttpUrl()

        assertEquals("https", url.scheme)
        assertEquals("fr.wikipedia.org", url.host)
        assertEquals(listOf("wiki", "Special:Search"), url.pathSegments)
        assertEquals("Jane Eyre & Co/1?", url.queryParameter("search"))
        assertEquals(setOf("search", "go"), url.queryParameterNames)
    }

    @Test
    fun webTranslationTargetsTheReadersLanguage() {
        val url = ReaderLookup.webTranslationUrl("Où est la gare ?", Locale.forLanguageTag("pt-BR")).toHttpUrl()

        assertEquals("translate.google.com", url.host)
        assertEquals("auto", url.queryParameter("sl"))
        assertEquals("pt", url.queryParameter("tl"))
        assertEquals("Où est la gare ?", url.queryParameter("text"))
    }

    @Test
    fun languageFallsBackToEnglishForUndeterminedLocales() {
        assertEquals("en", ReaderLookup.language(Locale.ROOT))
        assertEquals("he", ReaderLookup.language(Locale.forLanguageTag("he-IL")))
        assertEquals("fil", ReaderLookup.language(Locale.forLanguageTag("fil-PH")))
        assertEquals("zh", ReaderLookup.language(Locale.forLanguageTag("zh-Hant-TW")))
    }
}
