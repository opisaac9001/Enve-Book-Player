package com.enve.app.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test

class ReaderChromeContractTest {
    @Test
    fun printedPageLabelsDropTheirBrackets() {
        assertEquals("Page 154 of 229", readerPositionText(12, 300, hasPageList = true, currentPageLabel = "[154]", lastPageLabel = "[229]"))
        assertEquals("Page xiv of 229", readerPositionText(3, 300, hasPageList = true, currentPageLabel = "(xiv)", lastPageLabel = "229"))
        assertEquals("[]", printedPageLabel("[]"))
    }

    @Test
    fun timeLeftReadsNaturally() {
        assertEquals("~45m left", readingTimeLeft(45))
        assertEquals("~2h 5m left", readingTimeLeft(125))
    }
}
