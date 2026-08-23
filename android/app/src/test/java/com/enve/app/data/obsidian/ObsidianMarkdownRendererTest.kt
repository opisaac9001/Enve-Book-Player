package com.enve.app.data.obsidian

import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ObsidianMarkdownRendererTest {
    @Test
    fun renderBookIncludesFrontMatterAndStableHighlightMarkers() {
        val markdown = ObsidianMarkdownRenderer.renderBook(
            book = book(),
            bookId = "book-1",
            annotations = listOf(highlight(id = "a1")),
            exportedAtMs = 1_700_000_000_000,
        )

        assertTrue(markdown.contains("title: \"A Book\""))
        assertTrue(markdown.contains("series: \"The Series\""))
        assertTrue(markdown.contains("<!-- enve-highlight:a1 start -->"))
        assertTrue(markdown.contains("> Selected text"))
        assertTrue(markdown.contains("**Note:** Reader note"))
        assertTrue(markdown.contains("<!-- enve-highlight:a1 end -->"))
    }

    @Test
    fun magicMergePreservesExistingEditedBlocks() {
        val rendered = ObsidianMarkdownRenderer.renderBook(
            book = book(),
            bookId = "book-1",
            annotations = listOf(highlight(id = "a1", note = "New app note")),
        )
        val existing = """
            # Existing

            <!-- enve-highlight:a1 start -->
            User edited this block.
            <!-- enve-highlight:a1 end -->
        """.trimIndent()

        val merged = ObsidianMarkdownRenderer.merge(existing, rendered, ObsidianUpdatePolicy.MAGIC)

        assertTrue(merged.contains("User edited this block."))
        assertFalse(merged.contains("New app note"))
    }

    @Test
    fun appendMergeAddsOnlyNewBlocks() {
        val rendered = ObsidianMarkdownRenderer.renderBook(
            book = book(),
            bookId = "book-1",
            annotations = listOf(highlight(id = "a1"), highlight(id = "a2")),
        )
        val existing = """
            # Existing

            <!-- enve-highlight:a1 start -->
            Existing block.
            <!-- enve-highlight:a1 end -->
        """.trimIndent()

        val merged = ObsidianMarkdownRenderer.merge(existing, rendered, ObsidianUpdatePolicy.APPEND)

        assertEquals(1, Regex("enve-highlight:a1 start").findAll(merged).count())
        assertEquals(1, Regex("enve-highlight:a2 start").findAll(merged).count())
        assertTrue(merged.contains("## New Enve Exports"))
    }

    @Test
    fun filenameRemovesPathSeparatorsAndKeepsMarkdownExtension() {
        val filename = ObsidianMarkdownRenderer.filenameFor(
            book = book(title = "Bad / Path: Name?"),
            bookId = "book-1",
        )

        assertEquals("Bad Path Name.md", filename)
    }

    private fun book(title: String = "A Book") = Book(
        id = "book-1",
        title = title,
        author = "A. Writer",
        source = com.enve.core.data.model.BookSource.LOCAL,
        mediaType = AppMediaType.EBOOK,
        seriesName = "The Series",
        seriesNumber = "1",
        readProgress = 0.42f,
    )

    private fun highlight(
        id: String,
        note: String = "Reader note",
    ) = ReaderAnnotation(
        id = id,
        bookId = "book-1",
        kind = AnnotationKind.HIGHLIGHT.name,
        media = AnnotationMedia.EPUB.name,
        style = AnnotationStyle.HIGHLIGHT.name,
        colorHex = "#FFF59D",
        chapterId = "Chapter 1",
        selectedText = "Selected text",
        note = note,
        progression = 0.2,
        totalProgression = 0.4,
        createdAt = 1_000,
        updatedAt = 2_000,
    )
}
