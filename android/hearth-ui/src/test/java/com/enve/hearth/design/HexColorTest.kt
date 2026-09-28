package com.enve.hearth.design

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HexColorTest {

    @Test
    fun parsesOpaqueSixDigitHexWithOrWithoutHash() {
        assertEquals(EmberAccent, parseHexColor("#F5921A"))
        assertEquals(EmberAccent, parseHexColor(" f5921a "))
    }

    @Test
    fun expandsThreeDigitShorthand() {
        assertEquals(Color(0xFFFFCC00), parseHexColor("#FC0"))
    }

    @Test
    fun keepsAlphaFromEightDigitHex() {
        assertEquals(Color(0x80F5921A), parseHexColor("#80F5921A"))
    }

    @Test
    fun rejectsMalformedInput() {
        assertNull(parseHexColor(""))
        assertNull(parseHexColor("#12345"))
        assertNull(parseHexColor("#GGGGGG"))
        assertNull(parseHexColor("-12345"))
        assertNull(parseHexColor("yellow"))
    }
}
