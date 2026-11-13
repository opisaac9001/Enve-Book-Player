package com.enve.app.viewmodel

import org.junit.Assert.assertEquals
import org.junit.Test

class ReaderChapterMarksTest {
    @Test
    fun nestedChaptersReplaceSparseParts() {
        val toc = listOf(
            0 to ChapterMark(0.10f, "Part One"),
            1 to ChapterMark(0.101f, "Illustration"),
            1 to ChapterMark(0.103f, "Chapter 1"),
            1 to ChapterMark(0.20f, "Illustration"),
            1 to ChapterMark(0.202f, "Chapter 2"),
            0 to ChapterMark(0.50f, "Part Two"),
            1 to ChapterMark(0.502f, "Chapter 3"),
        )
        assertEquals(
            listOf(ChapterMark(0.10f, "Chapter 1"), ChapterMark(0.20f, "Chapter 2"), ChapterMark(0.50f, "Chapter 3")),
            readerChapterMarks(toc),
        )
    }

    @Test
    fun crowdedSubsectionsFallBackToTopLevel() {
        val chapters = (0 until 20).map { 0 to ChapterMark(it / 20f, "Chapter $it") }
        val sections = (0 until 80).map { 1 to ChapterMark(it / 80f + 0.006f, "Section $it") }
        assertEquals(20, readerChapterMarks((chapters + sections).sortedBy { it.second.start }).size)
    }
}
