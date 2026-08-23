package com.enve.app.data.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderTtsPageTextTest {
    @Test
    fun decodeStringResultHandlesJavascriptStringPayload() {
        assertEquals(
            "First line \"quoted\" second line",
            ReaderTtsPageText.decodeStringResult("\" First line \\\"quoted\\\" second line \""),
        )
    }

    @Test
    fun decodeStringResultRejectsEmptyPayloads() {
        assertNull(ReaderTtsPageText.decodeStringResult(null))
        assertNull(ReaderTtsPageText.decodeStringResult("null"))
        assertNull(ReaderTtsPageText.decodeStringResult("\"   \""))
    }

    @Test
    fun visibleTextScriptCapsRequestedTextLength() {
        val script = ReaderTtsPageText.visibleTextScript(maxChars = 50_000)

        assertTrue(script.contains("const maxChars = 20000;"))
        assertTrue(script.contains("document.createTreeWalker"))
        assertTrue(script.contains("getClientRects"))
    }
}
