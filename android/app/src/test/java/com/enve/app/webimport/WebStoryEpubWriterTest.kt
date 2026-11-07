package com.enve.app.webimport

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.Instant
import java.util.zip.ZipEntry
import java.util.zip.ZipFile

class WebStoryEpubWriterTest {

    @get:Rule
    val folder = TemporaryFolder()

    private val metadata = WebStoryMetadata(
        title = "Evil </dc:title><dc:creator>Injected</dc:creator> & \"Quotes\"",
        author = "<script>alert(1)</script>",
        description = "Line one\n\nLine ]]> two",
        language = "en",
        sourceUrl = "https://blog.example/story?a=1&b=2".toHttpUrl(),
    )

    private fun writeBook(): File {
        val file = folder.newFile("book.epub")
        WebStoryEpubWriter(file, maxBytes = 1024 * 1024).use { writer ->
            writer.addChapter("One <i>&</i>", "<p>First</p>", "en", "https://blog.example/chapter/1/?x=1&y=\"2\"".toHttpUrl())
            writer.addChapter("Two", "<p>Second</p>", "en", "https://blog.example/chapter/2/".toHttpUrl())
            writer.finish(metadata, Instant.parse("2026-11-06T10:15:30.123Z"))
        }
        return file
    }

    @Test
    fun mimetypeIsFirstAndStoredWithoutExtraField() {
        val file = writeBook()
        val bytes = file.readBytes()
        assertEquals("mimetype", bytes.copyOfRange(30, 38).toString(Charsets.US_ASCII))
        assertEquals(0, (bytes[28].toInt() and 0xFF) or ((bytes[29].toInt() and 0xFF) shl 8))
        assertEquals("application/epub+zip", bytes.copyOfRange(38, 58).toString(Charsets.US_ASCII))
        ZipFile(file).use { zip ->
            val first = zip.entries().nextElement()
            assertEquals("mimetype", first.name)
            assertEquals(ZipEntry.STORED, first.method)
        }
    }

    @Test
    fun packageMetadataIsEscapedAndWellFormed() {
        val entries = epubEntries(writeBook())
        assertTrue(entries.text("META-INF/container.xml").contains("full-path=\"OEBPS/content.opf\""))
        val opf = entries.text("OEBPS/content.opf")
        val document = parseXml(opf)
        val dc = "http://purl.org/dc/elements/1.1/"
        assertEquals(metadata.title, document.getElementsByTagNameNS(dc, "title").item(0).textContent)
        assertEquals(1, document.getElementsByTagNameNS(dc, "creator").length)
        assertEquals("<script>alert(1)</script>", document.getElementsByTagNameNS(dc, "creator").item(0).textContent)
        assertEquals("Line one\n\nLine ]]> two", document.getElementsByTagNameNS(dc, "description").item(0).textContent)
        assertEquals("https://blog.example/story?a=1&b=2", document.getElementsByTagNameNS(dc, "source").item(0).textContent)
        assertTrue(opf.contains("<meta property=\"dcterms:modified\">2026-11-06T10:15:30Z</meta>"))
        assertTrue(opf.contains("properties=\"nav\""))
        assertFalse(opf.contains("scripted"))
        assertFalse(opf.contains("remote-resources"))
        assertFalse(opf.contains("image/"))
        assertEquals(2, document.getElementsByTagName("itemref").length)
    }

    @Test
    fun chaptersCarryEscapedTitlesAndSourceLinks() {
        val entries = epubEntries(writeBook())
        val nav = entries.text("OEBPS/nav.xhtml")
        parseXml(nav)
        assertTrue(nav.contains("<a href=\"chapter-0001.xhtml\">One &lt;i&gt;&amp;&lt;/i&gt;</a>"))
        val chapter = entries.text("OEBPS/chapter-0001.xhtml")
        val document = parseXml(chapter)
        assertTrue(chapter.contains("<h1>One &lt;i&gt;&amp;&lt;/i&gt;</h1>"))
        val links = document.getElementsByTagName("a")
        assertEquals(1, links.length)
        assertEquals("https://blog.example/chapter/1/?x=1&y=%222%22", links.item(0).attributes.getNamedItem("href").nodeValue)
        assertTrue(entries.keys.none { it.endsWith(".js") || it.endsWith(".svg") || it.contains("images/") })
    }

    @Test
    fun exceedingTheByteBudgetFails() {
        val file = folder.newFile("large.epub")
        WebStoryEpubWriter(file, maxBytes = 64).use { writer ->
            val error = assertThrows(WebStoryImportException::class.java) {
                writer.addChapter("Large", "<p>${"x".repeat(200)}</p>", "en", "https://blog.example/".toHttpUrl())
            }
            assertEquals(WebStoryImportException.Reason.STORY_TOO_LARGE, error.reason)
        }
    }
}
