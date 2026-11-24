package com.enve.core.data.provider

import org.junit.Assert.*
import org.junit.Test

class CatalogFailureTest {
    @Test fun interruptedPageIncludesPreviouslyImportedBooksAndPageNumber() {
        val failed = CatalogImportReport(
            source = com.enve.core.data.model.BookSource.AUDIOBOOKSHELF,
            failures = listOf(CatalogFailure(CatalogFailureKind.NETWORK, CatalogImportStage.BOOKS)),
        ).afterPages(previousCount = 18_500, page = 37)
        assertEquals(18_500, failed.acceptedCount)
        assertEquals(37, failed.failures.single().page)
        assertFalse(failed.isComplete)
    }

    @Test fun partialPageAddsItsOwnAcceptedBooksAndKeepsProviderPage() {
        val failed = CatalogImportReport(
            acceptedCount = 499,
            failures = listOf(CatalogFailure(CatalogFailureKind.INVALID_PAGE, CatalogImportStage.BOOKS, page = 8)),
        ).afterPages(previousCount = 1000, page = 2)
        assertEquals(1499, failed.acceptedCount)
        assertEquals(8, failed.failures.single().page)
    }

    @Test fun preservesHttpStatusWithoutPersistingPrivateResponseText() {
        val denied = catalogFailureFor(IllegalStateException("Komga failed HTTP 403 private-response"))
        assertEquals(CatalogFailureKind.ACCESS_DENIED, denied.kind)
        assertEquals(403, denied.httpStatus)
        assertEquals(CatalogFailureKind.HTTP, catalogFailureFor(IllegalStateException("HTTP 404 wrong-path")).kind)
        assertEquals(CatalogFailureKind.ACCESS_DENIED, catalogFailureFor(Exception("Unauthorized: private-account")).kind)
        assertEquals(CatalogFailureKind.NETWORK, catalogFailureFor(java.io.IOException("private.invalid")).kind)
    }
}
