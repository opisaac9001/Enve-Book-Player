package com.enve.app.data.reader.search

import org.junit.Assert.assertEquals
import org.junit.Test

class TocTitlesTest {
    @Test
    fun searchResultsTakeTheChapterTitleOfTheirResource() {
        val titles = tocTitlesByReadingOrder(
            readingOrderHrefs = listOf("OEBPS/cover.xhtml", "OEBPS/ch1.xhtml", "OEBPS/ch1-2.xhtml", "OEBPS/ch2.xhtml"),
            toc = listOf(
                "OEBPS/ch1.xhtml" to "Chapter One",
                "OEBPS/ch1.xhtml" to "A Scene Inside Chapter One",
                "OEBPS/ch2.xhtml" to "Chapter Two",
            ),
        )

        assertEquals(listOf(null, "Chapter One", "Chapter One", "Chapter Two"), titles)
    }
}
