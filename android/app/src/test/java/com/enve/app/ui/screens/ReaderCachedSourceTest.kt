package com.enve.app.ui.screens

import com.enve.app.document.EbookSourceFormat
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ReaderCachedSourceTest {
    @get:Rule val directory = TemporaryFolder()
    private fun epub(name: String) = directory.newFile(name).also { it.writeBytes(byteArrayOf(0x50, 0x4b, 3, 4, 1)) }

    @Test fun cachedProviderFileIsAvailableWithoutAskingTheServer() {
        val file = epub("book.42.epub")
        assertEquals(file, ReaderCachedSource.find(directory.root, "book", EbookSourceFormat.EPUB))
        assertFalse(shouldUseReaderNetwork(true, networkAvailable = true))
        assertFalse(shouldUseReaderNetwork(true, networkAvailable = false))
    }

    @Test fun ambiguousEditionsRequireAnExplicitProviderFile() {
        epub("book.42.epub")
        val second = epub("book.43.epub")
        assertNull(ReaderCachedSource.find(directory.root, "book", EbookSourceFormat.EPUB))
        assertEquals(second, ReaderCachedSource.find(directory.root, "book", EbookSourceFormat.EPUB, "43"))
    }

    @Test fun ignoresUnrelatedBooksEmptyFilesAndServerErrorPages() {
        epub("book-other.epub")
        directory.newFile("book.epub").writeText("<html>Sign in</html>")
        directory.newFile("book.42.epub")
        assertNull(ReaderCachedSource.find(directory.root, "book", EbookSourceFormat.EPUB))
    }

    @Test fun matchingReadAloudArchiveIsNotMistakenForAnEpub() {
        epub("book.readaloud.epub")
        assertNull(ReaderCachedSource.find(directory.root, "book", EbookSourceFormat.EPUB))
    }
    @Test fun cachesAreSeparatedBySourceAndConnection() {
        val a = ReaderCachedSource.directory(directory.root, com.enve.core.data.model.BookSource.KAVITA, "one")
        val b = ReaderCachedSource.directory(directory.root, com.enve.core.data.model.BookSource.KAVITA, "two")
        val c = ReaderCachedSource.directory(directory.root, com.enve.core.data.model.BookSource.GRIMMORY, "one")
        assertNotEquals(a, b)
        assertNotEquals(a, c)
        assertEquals(java.io.File(directory.root, "ebooks"), ReaderCachedSource.directory(directory.root, com.enve.core.data.model.BookSource.LOCAL, null))
    }

    @Test fun legacyFileIsRecognizedOnlyByItsPublicationHash() {
        val file = epub("book.42.epub")
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
        assertTrue(ReaderCachedSource.matches(file, hash))
        assertFalse(ReaderCachedSource.matches(file, "0".repeat(64)))
        assertEquals("42", ReaderCachedSource.providerFileId(file, "book", EbookSourceFormat.EPUB))
        assertNull(ReaderCachedSource.providerFileId(file, "another", EbookSourceFormat.EPUB))
    }

}
