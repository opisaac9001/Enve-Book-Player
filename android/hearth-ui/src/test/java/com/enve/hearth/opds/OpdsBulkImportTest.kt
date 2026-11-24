package com.enve.hearth.opds

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.engine.opds.OpdsAcquisitionAction
import com.enve.engine.opds.OpdsAcquisitionOption
import com.enve.engine.opds.OpdsCatalogPage
import com.enve.engine.opds.OpdsShelfState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsBulkImportTest {
    private val book = Book(id = "b1", title = "Book", source = BookSource.OPDS)

    private fun option(action: OpdsAcquisitionAction, href: String, format: String? = null, unsupported: String? = null) =
        OpdsAcquisitionOption(action, href, action.name, format, unsupportedReason = unsupported)

    @Test
    fun singleDownloadableFileIsChosenAutomatically() {
        val item = opdsBulkItem(
            book,
            listOf(option(OpdsAcquisitionAction.OPEN, "/epub", "EPUB"), option(OpdsAcquisitionAction.SAMPLE, "/sample", "EPUB")),
        )
        assertEquals("/epub", item.chosenHref)
        assertEquals(OpdsBulkStatus.WAITING, item.status)
    }

    @Test
    fun severalFilesRequireAnExplicitChoice() {
        val item = opdsBulkItem(book, listOf(option(OpdsAcquisitionAction.OPEN, "/epub", "EPUB"), option(OpdsAcquisitionAction.OPEN, "/pdf", "PDF")))
        assertNull(item.chosenHref)
        assertTrue(item.needsChoice)
        val state = OpdsBulkImportState(OpdsBulkPhase.REVIEW, listOf(item))
        assertEquals(listOf("EPUB", "PDF"), state.formatChoices)
        assertTrue(state.ready.isEmpty())
    }

    @Test
    fun borrowOnlyAndDrmBooksAreSkippedWithReason() {
        val borrow = opdsBulkItem(book, listOf(option(OpdsAcquisitionAction.BORROW, "/borrow")))
        assertEquals(OpdsBulkStatus.SKIPPED, borrow.status)
        assertTrue(borrow.message!!.contains("borrowing"))
        val drm = opdsBulkItem(book, listOf(option(OpdsAcquisitionAction.UNSUPPORTED, "/lcp", unsupported = "Protected by Readium LCP")))
        assertEquals("Protected by Readium LCP", drm.message)
        assertEquals("No downloadable file", opdsBulkItem(book, emptyList()).message)
    }

    @Test
    fun duplicateHrefsCountOnce() {
        val item = opdsBulkItem(book, listOf(option(OpdsAcquisitionAction.OPEN, "/epub", "EPUB"), option(OpdsAcquisitionAction.OPEN, "/epub", "EPUB")))
        assertEquals("/epub", item.chosenHref)
    }

    @Test
    fun selectableBooksCoverWholeCurrentPageWithoutDuplicates() {
        val other = book.copy(id = "b2", title = "Other")
        val page = OpdsCatalogPage(
            url = "https://example.com/catalog",
            title = null,
            books = listOf(book),
            shelves = listOf(OpdsShelfState("Shelf", null, listOf(book, other), emptyList())),
        )
        val state = OpdsCatalogUiState(page = page, selection = setOf("b2", "missing"))
        assertEquals(listOf("b1", "b2"), state.selectableBooks.map(Book::id))
        assertEquals(listOf("b2"), state.selectedBooks.map(Book::id))
    }
}
