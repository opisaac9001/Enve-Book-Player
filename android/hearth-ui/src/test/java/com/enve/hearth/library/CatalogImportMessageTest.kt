package com.enve.hearth.library

import com.enve.core.data.provider.*
import org.junit.Assert.*
import org.junit.Test

class CatalogImportMessageTest {
    @Test fun skippedRecordIncludesCountAndSafeReason() {
        val message = libraryImportIssueMessage(CatalogImportReport(
            acceptedCount = 4999, rejections = mapOf(CatalogRejectionReason.MISSING_ID to 1),
        ))
        assertTrue(message.contains("4999"))
        assertTrue(message.contains("missing ID"))
        assertTrue(message.contains("incomplete"))
        assertTrue(message.contains("retry"))
    }

    @Test fun pageFailureAndAccessDenialHaveDifferentActions() {
        val page = libraryImportIssueMessage(CatalogImportReport(failures = listOf(
            CatalogFailure(CatalogFailureKind.INVALID_PAGE, CatalogImportStage.BOOKS, page = 9),
        )))
        val denied = libraryImportIssueMessage(CatalogImportReport(failures = listOf(
            CatalogFailure(CatalogFailureKind.ACCESS_DENIED, CatalogImportStage.BOOKS, httpStatus = 403),
        )))
        assertTrue(page.contains("page 10"))
        assertTrue(page.contains("server log"))
        assertTrue(denied.contains("403"))
        assertTrue(denied.contains("permissions"))
    }
}
