package com.enve.app.data.reader.search

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SearchTextTest {
    @Test
    fun indexNormalizationMatchesMappedNormalization() {
        listOf("cafe\u0301", "Élan  Vital", "İstanbul", "한글", "東京", "😀 🐈", "\n\t Alpha\u00a0beta").forEach {
            assertEquals(SearchText.normalize(it).value, SearchText.fold(it))
        }
    }

    @Test
    fun foldPreservesOffsets() {
        val original = "Café İstanbul ÅNGSTRÖM"
        val folded = SearchText.fold(original)
        assertEquals(original.length, folded.length)
        assertEquals("cafe istanbul angstrom", folded)
    }

    @Test
    fun foldLeavesHangulSyllablesDistinct() {
        assertEquals(SearchText.fold("한"), SearchText.fold("한"))
        assertTrue(SearchText.fold("한") != SearchText.fold("함"))
    }

    @Test
    fun chunksOverlapByMaxQueryLength() {
        val starts = SearchText.chunkStarts(SearchText.CHUNK_SIZE * 3)
        val step = SearchText.CHUNK_SIZE - SearchText.CHUNK_OVERLAP
        assertEquals(0, starts.first())
        starts.zipWithNext { a, b -> assertEquals(step, b - a) }
        assertTrue(starts.last() + SearchText.CHUNK_SIZE >= SearchText.CHUNK_SIZE * 3)
    }

    @Test
    fun overlappedChunksYieldEachMatchExactlyOnce() {
        val filler = "x".repeat(SearchText.CHUNK_SIZE * 3)
        val needle = "lexicon"
        val text = StringBuilder(filler).apply {
            replace(10, 10 + needle.length, needle)
            replace(3_900, 3_900 + needle.length, needle)
            replace(7_500, 7_500 + needle.length, needle)
        }.toString()

        val offsets = mutableListOf<Int>()
        SearchText.chunkStarts(text.length).forEachIndexed { chunkIndex, start ->
            val end = minOf(start + SearchText.CHUNK_SIZE, text.length)
            val folded = SearchText.fold(text.substring(start, end))
            SearchText.matches(
                folded = folded,
                foldedQuery = needle,
                wholeWords = false,
                minMatchEnd = if (chunkIndex > 0) SearchText.CHUNK_OVERLAP else 0,
                limit = Int.MAX_VALUE,
            ).forEach { offsets += start + it }
        }

        assertEquals(listOf(10, 3_900, 7_500), offsets)
    }

    @Test
    fun wholeWordsRejectsInfixButPartialKeepsIt() {
        val folded = SearchText.fold("Biology and ology")
        assertEquals(listOf(12), SearchText.matches(folded, "ology", true, 0, 10))
        assertEquals(listOf(2, 12), SearchText.matches(folded, "ology", false, 0, 10))
    }

    @Test
    fun ftsPhraseCannotCarryMatchOperators() {
        val tokens = SearchText.asciiTokens(SearchText.fold("""cat" OR "dog* NEAR/3"""))
        assertEquals("\"cat or dog near 3\"", SearchText.ftsPhrase(tokens))
    }

    @Test
    fun normalizationMapsCombiningAccentsAndWhitespaceToOriginalOffsets() {
        val text = "intro e\u0301lan\n\n  vital body"
        val normalized = SearchText.normalize(text)
        val start = normalized.value.indexOf("elan vital")
        val end = start + "elan vital".length
        assertEquals("e\u0301lan\n\n  vital", text.substring(normalized.starts[start], normalized.ends[end - 1]))
        assertEquals("é", "é".substring(SearchText.normalize("é").starts[0], SearchText.normalize("é").ends[0]))
    }
}
