package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.dto.BookSummaryDto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GrimmoryCatalogFallbackTest {

    @Test
    fun `successful populated app response stays on app catalog`() {
        assertFalse(shouldUseLegacyGrimmoryCatalog(responseCode = 200, firstPageItemCount = 12))
    }

    @Test
    fun `successful empty app response falls back to legacy catalog`() {
        assertTrue(shouldUseLegacyGrimmoryCatalog(responseCode = 200, firstPageItemCount = 0))
    }

    @Test
    fun `successful response without a decodable body falls back to legacy catalog`() {
        assertTrue(shouldUseLegacyGrimmoryCatalog(responseCode = 200, firstPageItemCount = null))
    }

    @Test
    fun `unsupported and failed app endpoints fall back to legacy catalog`() {
        listOf(401, 403, 404, 405, 500, 501).forEach { responseCode ->
            assertTrue(
                "Expected HTTP $responseCode to use the legacy catalog",
                shouldUseLegacyGrimmoryCatalog(responseCode, firstPageItemCount = null),
            )
        }
    }
    @Test
    fun `populated app catalog rejects empty legacy fallback`() {
        assertThrows(IllegalStateException::class.java) {
            consistentGrimmoryCatalogFallback(listOf(BookSummaryDto(id = "ebook")), emptyList())
        }
    }

    @Test
    fun `populated app catalog rejects partial legacy fallback`() {
        val books = listOf(BookSummaryDto(id = "audio"), BookSummaryDto(id = "ebook"))
        assertThrows(IllegalStateException::class.java) {
            consistentGrimmoryCatalogFallback(books, books.take(1))
        }
    }

    @Test
    fun `consistent complete empty catalog remains authoritative`() {
        assertEquals(emptyList<BookSummaryDto>(), consistentGrimmoryCatalogFallback(emptyList(), emptyList()))
    }

    @Test
    fun `complete legacy response accepts additional books and recovers after conflict`() {
        val app = listOf(BookSummaryDto(id = "ebook"))
        assertThrows(IllegalStateException::class.java) { consistentGrimmoryCatalogFallback(app, emptyList()) }
        val legacy = app + BookSummaryDto(id = "audio")
        assertEquals(legacy, consistentGrimmoryCatalogFallback(app, legacy))
    }
}
