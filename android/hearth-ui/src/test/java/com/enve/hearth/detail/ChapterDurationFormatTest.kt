package com.enve.hearth.detail

import org.junit.Assert.assertEquals
import org.junit.Test

class ChapterDurationFormatTest {
    @Test
    fun chaptersUnderAMinuteShowSeconds() {
        assertEquals("45s", fmtChapter(45))
        assertEquals("0s", fmtChapter(0))
        assertEquals("1m", fmtChapter(60))
        assertEquals("12m", fmtChapter(754))
        assertEquals("1h 0m", fmtChapter(3_600))
    }
}
