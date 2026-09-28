package com.enve.core.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HighlightColorTest {

    @Test
    fun hexValuesPassThroughWithLeadingHash() {
        assertEquals("#FFF59D", highlightColorHex("#FFF59D"))
        assertEquals("#fff59d", highlightColorHex("fff59d"))
        assertEquals("#80FACC15", highlightColorHex(" #80FACC15 "))
    }

    @Test
    fun koreaderColorNamesResolveToThePalette() {
        assertEquals("#F472B6", highlightColorHex("pink"))
        assertEquals("#FACC15", highlightColorHex("Yellow"))
        assertEquals("#84CC16", highlightColorHex("olive"))
    }

    @Test
    fun unknownValuesResolveToNull() {
        assertNull(highlightColorHex("chartreuse"))
        assertNull(highlightColorHex("#12345"))
    }
}
