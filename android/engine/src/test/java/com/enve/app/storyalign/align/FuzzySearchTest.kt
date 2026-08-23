package com.enve.app.storyalign.align

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FuzzySearchTest {
    private val fs = FuzzySearcher()

    @Test fun exactSubstringMatch() {
        val haystack = "the quick brown fox jumps over"
        val (match, index) = fs.findNearestMatch("quick brown fox", haystack, 2)!!
        assertEquals(4, index)
        assertTrue(match.contains("quick brown fox"))
    }

    @Test fun fuzzyMatchWithOneTypo() {
        val haystack = "the quick brown fox jumps over"
        val result = fs.findNearestMatch("quick brown fax", haystack, 2)
        assertNotNull(result)
        assertTrue(result!!.second in 3..5)
        assertTrue(result.first.contains("brown f"))
    }

    @Test fun noMatchBeyondDistance() {
        val haystack = "completely different words here now"
        val result = fs.findNearestMatch("quick brown fox jumps", haystack, 2)
        assertNull(result)
    }

    @Test fun ngramIndexFindsChunk() {
        val idx = NGramIndex("the quick brown fox jumps over the lazy dog")
        val candidates = idx.candidates("the quick brown fox jumps")
        assertTrue(candidates.contains(0))
    }

    @Test fun ngramIndexEmptyForAbsentChunk() {
        val idx = NGramIndex("the quick brown fox jumps over the lazy dog")
        assertTrue(idx.candidates("zebra yak wombat quokka narwhal").isEmpty())
    }

    @Test fun ngramIndexShortChunkEmpty() {
        val idx = NGramIndex("the quick brown fox jumps")
        assertTrue(idx.candidates("too short").isEmpty())
    }
}
