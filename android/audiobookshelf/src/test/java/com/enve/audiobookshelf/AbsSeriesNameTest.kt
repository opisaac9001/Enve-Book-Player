package com.enve.audiobookshelf

import org.junit.Assert.assertEquals
import org.junit.Test

class AbsSeriesNameTest {

    @Test
    fun seriesNamesSplitIntoNameAndSequence() {
        assertEquals(
            listOf(AbsSeriesEntry("The Expanse", "3"), AbsSeriesEntry("Space Opera", "1.5")),
            absSeriesEntries("The Expanse #3, Space Opera #1.5"),
        )
        assertEquals(listOf(AbsSeriesEntry("Jane Austen", null)), absSeriesEntries("Jane Austen"))
        assertEquals(emptyList<AbsSeriesEntry>(), absSeriesEntries(null))
    }
}
