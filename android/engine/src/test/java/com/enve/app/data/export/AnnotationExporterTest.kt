package com.enve.app.data.export

import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.ReaderAnnotation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AnnotationExporterTest {

    @Test fun csvQuotesEscapesAndGuardsFormulas() {
        val csv = AnnotationExporter.export(
            listOf(annotation("a", selectedText = "He said \"hi\",\nthen left", note = "=HYPERLINK(\"http://x\")")),
            "Book, Vol. 1",
            "Author",
            AnnotationExporter.Format.CSV,
        )

        assertTrue(csv.contains("\"He said \"\"hi\"\",\nthen left\""))
        assertTrue(csv.contains("\"'=HYPERLINK(\"\"http://x\"\")\""))
        assertTrue(csv.contains("\"Book, Vol. 1\",\"Author\""))
        assertEquals("'+1", AnnotationExporter.csvField("+1").removeSurrounding("\""))
        assertEquals("'@cmd", AnnotationExporter.csvField("@cmd").removeSurrounding("\""))
        assertEquals("plain", AnnotationExporter.csvField("plain").removeSurrounding("\""))
    }

    @Test fun htmlEscapesTextAndRejectsUnsafeColors() {
        val html = AnnotationExporter.export(
            listOf(
                annotation(
                    "a",
                    selectedText = "<script>alert('x')</script>",
                    note = "Tom & \"Jerry\"",
                    colorHex = "red;background:url(javascript:alert(1))",
                    tagsJson = "[\"<b>tag</b>\"]",
                ),
            ),
            "<i>Title</i>",
            "O'Brien",
            AnnotationExporter.Format.HTML,
        )

        assertFalse(html.contains("<script>"))
        assertTrue(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"))
        assertTrue(html.contains("Tom &amp; &quot;Jerry&quot;"))
        assertTrue(html.contains("<title>&lt;i&gt;Title&lt;/i&gt;</title>"))
        assertTrue(html.contains("O&#39;Brien"))
        assertTrue(html.contains("&lt;b&gt;tag&lt;/b&gt;"))
        assertFalse(html.contains("javascript"))
        assertTrue(html.contains("border-color:#FFF59D"))
    }

    @Test fun allFormatsSkipDeletedAnnotations() {
        val annotations = listOf(
            annotation("live", selectedText = "Visible quote"),
            annotation("gone", selectedText = "Deleted quote", deletedAt = 10L),
        )
        listOf(
            AnnotationExporter.Format.MARKDOWN,
            AnnotationExporter.Format.PLAIN_TEXT,
            AnnotationExporter.Format.CSV,
            AnnotationExporter.Format.HTML,
        ).forEach { format ->
            val output = AnnotationExporter.export(annotations, "Book", null, format)
            assertTrue(format.name, output.contains("Visible quote"))
            assertFalse(format.name, output.contains("Deleted quote"))
        }
    }

    @Test fun markdownGroupsEveryBookAndKeepsTitlesOnOneLine() {
        val markdown = AnnotationExporter.export(
            listOf(
                AnnotationExportBook("First\nBook", "Ann", listOf(annotation("a", selectedText = "Line one\r\nLine two"))),
                AnnotationExportBook(
                    "Second",
                    null,
                    listOf(annotation("b", note = "Bookmark note", kind = AnnotationKind.BOOKMARK, tagsJson = "[\"to read\"]")),
                ),
            ),
            AnnotationExporter.Format.MARKDOWN,
        )

        assertTrue(markdown.contains("# First Book\n*by Ann*"))
        assertTrue(markdown.contains("> Line one\n> Line two"))
        assertTrue(markdown.contains("# Second\n"))
        assertTrue(markdown.contains("## Bookmarks"))
        assertTrue(markdown.contains("#to-read"))
        assertTrue(markdown.indexOf("# First Book") < markdown.indexOf("# Second"))
    }

    @Test fun plainTextNamesBooksOnlyForMultiBookExports() {
        val single = AnnotationExporter.export(listOf(annotation("a", selectedText = "Quote")), "Book", "Ann", AnnotationExporter.Format.PLAIN_TEXT)
        val multi = AnnotationExporter.export(
            listOf(
                AnnotationExportBook("One", "Ann", listOf(annotation("a", selectedText = "First"))),
                AnnotationExportBook("Two", null, listOf(annotation("b", selectedText = "Second"))),
            ),
            AnnotationExporter.Format.PLAIN_TEXT,
        )

        assertEquals("Quote", single)
        assertTrue(multi.startsWith("One by Ann\n\nFirst"))
        assertTrue(multi.contains("Two\n\nSecond"))
    }

    @Test fun locationLabelsUseRealPositionsOnly() {
        assertEquals("Page 3", AnnotationExporter.locationLabel(annotation("p", media = AnnotationMedia.PDF, pdfPage = 2)))
        assertEquals("1:01:01", AnnotationExporter.locationLabel(annotation("a", media = AnnotationMedia.AUDIOBOOK, audioPositionMs = 3_661_000)))
        assertEquals("42%", AnnotationExporter.locationLabel(annotation("e", totalProgression = 0.42)))
        assertEquals(null, AnnotationExporter.locationLabel(annotation("e")))
    }

    @Test fun malformedTagsAreIgnored() {
        assertEquals(emptyList<String>(), AnnotationExporter.tags(annotation("a", tagsJson = "{oops")))
        assertEquals(emptyList<String>(), AnnotationExporter.tags(annotation("a", tagsJson = "{\"a\":1}")))
        assertEquals(listOf("one", "two"), AnnotationExporter.tags(annotation("a", tagsJson = "[\"one\", \" \", \"two\", null]")))
    }

    @Test fun shareFileNamesAreFilesystemSafe() {
        assertEquals("a b c highlights", AnnotationShareFiles.fileName("a/b:c\u0000 highlights"))
        assertEquals("Enve highlights", AnnotationShareFiles.fileName(" ... "))
        assertEquals(80, AnnotationShareFiles.fileName("x".repeat(200)).length)
    }

    private fun annotation(
        id: String,
        selectedText: String = "",
        note: String = "",
        kind: AnnotationKind = AnnotationKind.HIGHLIGHT,
        media: AnnotationMedia = AnnotationMedia.EPUB,
        colorHex: String = "#FFF59D",
        tagsJson: String = "[]",
        deletedAt: Long? = null,
        pdfPage: Int? = null,
        audioPositionMs: Long? = null,
        totalProgression: Double? = null,
    ) = ReaderAnnotation(
        id = id,
        bookId = "book",
        kind = kind.name,
        media = media.name,
        colorHex = colorHex,
        selectedText = selectedText,
        note = note,
        tagsJson = tagsJson,
        deletedAt = deletedAt,
        pdfPage = pdfPage,
        audioPositionMs = audioPositionMs,
        totalProgression = totalProgression,
        createdAt = 1_700_000_000_000L,
        updatedAt = 1_700_000_000_000L,
    )
}
