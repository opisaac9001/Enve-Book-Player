package com.enve.app.ui.screens

import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.*
import org.junit.Test

class PendingReaderPageTest {
    private val book = Book("reading", "A Book", mediaType = AppMediaType.EBOOK, source = BookSource.LOCAL,
        connectionId = "one", primaryFileType = "PDF", epubProgress = 0.25f, epubLocator = "{\"page\":5}").toCachedBook()
    private val pending = PendingProgressPush("reading", BookSource.LOCAL.name, "one", "EBOOK", 0.25f, false, 100)

    @Test fun pendingRewindRestoresTheAcceptedPageRatherThanTheFurthestPage() {
        assertEquals(4, commandReaderPage(book, pending, ReaderFormat.PDF, 20, book.cacheKey, BookSource.LOCAL.name, "one"))
        assertEquals(4, commandReaderPage(book.copy(primaryFileType = "CBZ", epubLocator = "cbz-page:5"), pending, ReaderFormat.CBZ, 20, book.cacheKey, BookSource.LOCAL.name, "one"))
        assertEquals(0, commandReaderPage(book.copy(epubProgress = 0f, epubLocator = null), pending.copy(percentage = 0f), ReaderFormat.PDF, 20, book.cacheKey, BookSource.LOCAL.name, "one"))
    }

    @Test fun unrelatedOrStaleWritesDoNotOverrideOrdinaryReaderRestore() {
        assertNull(commandReaderPage(book, null, ReaderFormat.PDF, 20, book.cacheKey, BookSource.LOCAL.name, "one"))
        assertNull(commandReaderPage(book, pending.copy(connectionKey = "two"), ReaderFormat.PDF, 20, book.cacheKey, BookSource.LOCAL.name, "one"))
        assertNull(commandReaderPage(book, pending.copy(source = BookSource.AUDIOBOOKSHELF.name), ReaderFormat.PDF, 20, book.cacheKey, BookSource.LOCAL.name, "one"))
        assertNull(commandReaderPage(book, pending.copy(bookId = "other"), ReaderFormat.PDF, 20, book.cacheKey, BookSource.LOCAL.name, "one"))
        assertNull(commandReaderPage(book, pending.copy(percentage = 0.9f), ReaderFormat.PDF, 20, book.cacheKey, BookSource.LOCAL.name, "one"))
        assertNull(commandReaderPage(book, pending.copy(mediaType = "AUDIOBOOK"), ReaderFormat.PDF, 20, book.cacheKey, BookSource.LOCAL.name, "one"))
    }
    @Test fun explicitSharedPageSurvivesLocalOnlyOrAcknowledgedWritesAndUnknownOriginalCount() {
        val marked = book.copy(epubLocator = "{\"page\":5,\"enveSharedPosition\":true}", pageCount = null)
        assertEquals(4, commandReaderPage(marked, null, ReaderFormat.PDF, 100, book.cacheKey, BookSource.LOCAL.name, "one"))
        val start = marked.copy(epubLocator = "{\"enveSharedPosition\":true}", epubProgress = 0f)
        assertEquals(0, commandReaderPage(start, null, ReaderFormat.PDF, 100, book.cacheKey, BookSource.LOCAL.name, "one"))
        assertNull(commandReaderPage(marked, null, ReaderFormat.PDF, 3, book.cacheKey, BookSource.LOCAL.name, "one"))
        assertNull(commandReaderPage(marked, null, ReaderFormat.EPUB, 100, book.cacheKey, BookSource.LOCAL.name, "one"))
        assertNull(commandReaderPage(marked, null, ReaderFormat.PDF, 100, book.cacheKey, BookSource.LOCAL.name, "two"))
        assertNull(commandReaderPage(marked, null, ReaderFormat.PDF, 100, book.cacheKey, BookSource.AUDIOBOOKSHELF.name, "one"))
        assertNull(commandReaderPage(marked.copy(epubLocator = "{\"page\":\"5\",\"enveSharedPosition\":true}"), null,
            ReaderFormat.PDF, 100, book.cacheKey, BookSource.LOCAL.name, "one"))
    }

}
