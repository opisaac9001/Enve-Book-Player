package com.enve.app.ui.screens

import org.junit.Assert.*
import org.junit.Test

class InitialLocatorResourceTest {
    private val resources = listOf("OPS/chapter%201.xhtml", "OPS/chapter2.xhtml")

    @Test fun normalizedReadingOrderResourcesCanRestoreAnExactPosition() {
        assertTrue(locatorResourceInReadingOrder("./OPS/chapter%201.xhtml", resources))
        assertTrue(locatorResourceInReadingOrder("OPS/chapter2.xhtml#paragraph", resources))
        assertTrue(locatorResourceInReadingOrder("OPS/chapter 1.xhtml", resources))
    }

    @Test fun anotherEditionsChapterMustUseThePercentageFallback() {
        assertFalse(locatorResourceInReadingOrder("Text/sender-chapter.xhtml", resources))
        assertFalse(locatorResourceInReadingOrder("", resources))
        assertFalse(locatorResourceInReadingOrder("OPS/chapter2.xhtml", emptyList()))
    }
}
