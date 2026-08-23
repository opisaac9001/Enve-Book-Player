package com.enve.core.data.importing

import org.junit.Assert.assertEquals
import org.junit.Test

class AudiobookFileGroupingTest {
    @Test
    fun explicitBooksRemainSeparate() {
        val files = listOf("Book 1.mp3", "Book 2.mp3")
        assertEquals(listOf(listOf("Book 1.mp3"), listOf("Book 2.mp3")), groups(files))
    }

    @Test
    fun chaptersWithTitlesRemainOneOrderedBook() {
        val files = listOf(
            "Chapter 16 - The Chamber of Secrets.mp3",
            "Credits.mp3",
            "Chapter 2 - Dobby's Warning.mp3",
            "Opening Credits.mp3",
            "Chapter 1 - The Worst Birthday.mp3",
        )
        assertEquals(
            listOf(
                listOf(
                    "Opening Credits.mp3",
                    "Chapter 1 - The Worst Birthday.mp3",
                    "Chapter 2 - Dobby's Warning.mp3",
                    "Chapter 16 - The Chamber of Secrets.mp3",
                    "Credits.mp3",
                ),
            ),
            groups(files),
        )
    }

    @Test
    fun chaptersGroupByBookPrefix() {
        val files = listOf(
            "Book 1 - Chapter 1.mp3",
            "Book 2 - Chapter 1.mp3",
            "Book 1 - Chapter 2.mp3",
        )
        assertEquals(listOf(1, 2), groups(files).map(List<String>::size).sorted())
    }

    @Test
    fun explicitChapterSignalOverridesM4aContainer() {
        val files = listOf("Chapter 1.m4a", "Chapter 2.m4a")
        assertEquals(listOf(files), groups(files))
    }

    @Test
    fun ambiguityDefaultsToOneBook() {
        val files = listOf("Dune.mp3", "Dune Messiah.mp3")
        assertEquals(listOf(files), groups(files))
    }

    @Test
    fun fullBookSizeEvidenceSplitsOnlyWithoutChapterEvidence() {
        val fullBooks = listOf("Flawless.mp3", "Wild Card.mp3")
        assertEquals(2, groups(fullBooks, size = { AudiobookFileGrouping.MINIMUM_STANDALONE_BOOK_SIZE_BYTES }).size)

        val chapters = listOf("Chapter 1.mp3", "Chapter 2.mp3")
        assertEquals(1, groups(chapters, size = { AudiobookFileGrouping.MINIMUM_STANDALONE_BOOK_SIZE_BYTES }).size)
    }

    @Test
    fun forcedTrackBecomesStandalone() {
        val files = listOf("First title.mp3", "Second title.mp3")
        val grouped = AudiobookFileGrouping.groups(
            files = files,
            name = { it },
            forcedStandalone = { it == "Second title.mp3" },
        )
        assertEquals(2, grouped.size)
        assertEquals(listOf(1, 1), grouped.map(List<String>::size).sorted())
    }

    private fun groups(files: List<String>, size: (String) -> Long = { 0L }): List<List<String>> =
        AudiobookFileGrouping.groups(files, name = { it }, sizeBytes = size)
}
