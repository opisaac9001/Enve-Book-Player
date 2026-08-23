package com.enve.app.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class LocalCastServerRangeTest {
    @Test
    fun resolvesOpenEndedRange() {
        assertEquals(
            HttpRange.Partial(start = 250L, endInclusive = 999L),
            resolveHttpRange("bytes=250-", length = 1_000L),
        )
    }

    @Test
    fun resolvesSuffixRange() {
        assertEquals(
            HttpRange.Partial(start = 750L, endInclusive = 999L),
            resolveHttpRange("bytes=-250", length = 1_000L),
        )
    }

    @Test
    fun resolvesBoundedRange() {
        assertEquals(
            HttpRange.Partial(start = 100L, endInclusive = 199L),
            resolveHttpRange("bytes=100-199", length = 1_000L),
        )
    }

    @Test
    fun rejectsRangeBeyondEndOfFile() {
        assertEquals(
            HttpRange.Unsatisfiable,
            resolveHttpRange("bytes=1000-", length = 1_000L),
        )
    }

    @Test
    fun leavesRequestWithoutRangeAsFullResponse() {
        assertEquals(HttpRange.Full, resolveHttpRange(null, length = 1_000L))
    }

    @Test
    fun ignoresUnsupportedRangeUnit() {
        assertEquals(HttpRange.Full, resolveHttpRange("items=0-1", length = 1_000L))
    }

    @Test
    fun ignoresMultipleRangesWhenMultipartIsUnsupported() {
        assertEquals(HttpRange.Full, resolveHttpRange("bytes=0-10,20-30", length = 1_000L))
    }

    @Test
    fun rejectsReversedRange() {
        assertEquals(
            HttpRange.Unsatisfiable,
            resolveHttpRange("bytes=200-100", length = 1_000L),
        )
    }
}
