package com.enve.komga

import com.enve.komga.dto.KomgaBookDto
import com.enve.komga.dto.KomgaMediaDto
import com.enve.komga.dto.readerFileType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class KomgaReaderFileTypeTest {
    private fun book(media: KomgaMediaDto?, url: String? = null) = KomgaBookDto(
        id = "b", seriesId = "s", seriesTitle = "Series", libraryId = "l", name = "Issue", url = url, media = media,
    )

    @Test
    fun mapsAnalyzedArchiveMediaTypes() {
        assertEquals("CBZ", book(KomgaMediaDto(mediaType = "application/zip", mediaProfile = "DIVINA")).readerFileType())
        assertEquals("CBR", book(KomgaMediaDto(mediaType = "application/x-rar-compressed; version=4", mediaProfile = "DIVINA")).readerFileType())
        assertEquals("CBX", book(KomgaMediaDto(mediaType = "application/x-7z-compressed", mediaProfile = "DIVINA")).readerFileType())
        assertEquals("CBX", book(KomgaMediaDto(mediaType = "application/x-tar", mediaProfile = "DIVINA")).readerFileType())
        assertEquals("CBX", book(KomgaMediaDto(mediaType = "", mediaProfile = "DIVINA")).readerFileType())
    }

    @Test
    fun mediaProfileDecidesEpubAndPdf() {
        assertEquals("EPUB", book(KomgaMediaDto(mediaType = "application/epub+zip", mediaProfile = "EPUB")).readerFileType())
        assertEquals("EPUB", book(KomgaMediaDto(mediaType = "application/epub+zip", mediaProfile = "EPUB", epubDivinaCompatible = false)).readerFileType())
        assertEquals("CBZ", book(KomgaMediaDto(mediaType = "application/epub+zip", mediaProfile = "EPUB", epubDivinaCompatible = true)).readerFileType())
        assertEquals("PDF", book(KomgaMediaDto(mediaType = "application/pdf", mediaProfile = "PDF")).readerFileType())
        assertEquals("EPUB", book(KomgaMediaDto(mediaType = "application/epub+zip")).readerFileType())
    }

    @Test
    fun unanalyzedBooksFallBackToTheFileExtension() {
        assertEquals("CBZ", book(KomgaMediaDto(status = "UNKNOWN", mediaType = ""), "file:/comics/Saga/Saga%20001.cbz").readerFileType())
        assertEquals("CBR", book(null, "file:/comics/Issue.CBR").readerFileType())
        assertEquals("CBX", book(KomgaMediaDto(), "file:/comics/Issue.cb7").readerFileType())
        assertEquals("CBX", book(KomgaMediaDto(), "file:/comics/Issue.cbt").readerFileType())
        assertEquals("EPUB", book(KomgaMediaDto(), "file:/books/Novel.epub").readerFileType())
        assertEquals("PDF", book(KomgaMediaDto(), "file:/books/Scan.pdf").readerFileType())
        assertNull(book(KomgaMediaDto(), "file:/books/v1.0/README").readerFileType())
        assertNull(book(null).readerFileType())
    }
}
