package com.enve.app.data.offline

import com.enve.app.data.repository.preservingLocalProgress
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadedReadAloudMetadataTest {
    private val book = Book(id = "42", title = "Narrated EPUB", source = BookSource.GRIMMORY,
        connectionId = "grimmory-1", mediaType = AppMediaType.EBOOK, primaryFileType = "EPUB")

    @Test
    fun downloadedSmilMakesNarrationAvailableWithoutServerMetadata() {
        epub(narrated = true).let { file ->
            try {
                val detected = book.withDownloadedReadAloud(file, "epub")
                assertTrue(detected.readAlongAvailable)
                assertTrue(detected.hasAudio)
                assertTrue(detected.hasEbook)
            } finally { file.delete() }
        }
    }

    @Test
    fun ordinaryEpubDoesNotGainNarration() {
        epub(narrated = false).let { file ->
            try { assertFalse(book.withDownloadedReadAloud(file, "epub").readAlongAvailable) }
            finally { file.delete() }
        }
    }

    @Test
    fun serverRefreshPreservesDetectedNarrationWithSyncOnOrOff() {
        val detected = book.copy(readAlongAvailable = true, hasAudio = true, hasEbook = true).toCachedBook(1_000L)
        for (sync in listOf(true, false)) {
            val refreshed = book.toCachedBook(2_000L).preservingLocalProgress(detected, allowServerProgress = sync)
            assertTrue(refreshed.readAlongAvailable)
            assertTrue(refreshed.hasAudio)
            assertTrue(refreshed.hasEbook)
        }
    }

    private fun epub(narrated: Boolean): File {
        val file = File.createTempFile("narrated-metadata-", ".epub")
        ZipOutputStream(file.outputStream()).use { zip ->
            val overlay = if (narrated) "media-overlay=\"overlay\"" else ""
            val entries = mapOf(
                "META-INF/container.xml" to "<container><rootfiles><rootfile full-path=\"OEBPS/content.opf\"/></rootfiles></container>",
                "OEBPS/content.opf" to "<package><manifest><item id=\"text\" href=\"chapter.xhtml\" $overlay/><item id=\"overlay\" href=\"chapter.smil\"/></manifest><spine><itemref idref=\"text\"/></spine></package>",
                "OEBPS/chapter.xhtml" to "<html><body><p id=\"sentence\">A narrated sentence.</p></body></html>",
                "OEBPS/chapter.smil" to "<smil><body><par><text src=\"chapter.xhtml#sentence\"/><audio src=\"audio.mp3\" clipBegin=\"0s\" clipEnd=\"5s\"/></par></body></smil>",
            )
            entries.forEach { (name, content) ->
                zip.putNextEntry(ZipEntry(name))
                zip.write(content.toByteArray())
                zip.closeEntry()
            }
        }
        return file
    }
}
