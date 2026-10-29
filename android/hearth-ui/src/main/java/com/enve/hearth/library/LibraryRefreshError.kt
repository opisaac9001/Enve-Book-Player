package com.enve.hearth.library

import com.enve.core.data.provider.CatalogFailureKind
import com.enve.core.data.provider.CatalogImportReport
import com.enve.core.data.provider.CatalogRejectionReason

internal fun libraryRefreshErrorMessage(error: String): String {
    val status = Regex("HTTP\\s+(\\d{3})").find(error)?.groupValues?.get(1)
    return if (status != null) {
        "The server returned HTTP $status. Check your source connection and try again."
    } else {
        "Check your source connection and try again."
    }
}

internal fun libraryImportIssueMessage(report: CatalogImportReport): String = buildList {
    add("${report.source.displayName}: ${report.acceptedCount} books read from the server.")
    if (report.rejectedCount > 0) {
        val reasons = report.rejections.map { (reason, count) ->
            val description = when (reason) {
                CatalogRejectionReason.MISSING_ID -> "missing ID"
                CatalogRejectionReason.INVALID_ID -> "invalid ID"
                CatalogRejectionReason.INVALID_RECORD -> "invalid book data"
                CatalogRejectionReason.WRONG_LIBRARY -> "unexpected library"
                CatalogRejectionReason.MISSING_INVENTORY -> "missing format data"
            }
            "$count $description"
        }.joinToString(", ")
        val records = if (report.rejectedCount == 1) "record" else "records"
        add("${report.rejectedCount} $records skipped ($reasons). Correct the source data and retry.")
    }
    report.failures.firstOrNull()?.let { failure ->
        val page = failure.page?.let { " on page ${it + 1}" }.orEmpty()
        add(when (failure.kind) {
            CatalogFailureKind.ACCESS_DENIED -> "Access denied (HTTP ${failure.httpStatus}). Check this account's library permissions and retry."
            CatalogFailureKind.HTTP -> "The server returned HTTP ${failure.httpStatus}$page. Retry when the server is available."
            CatalogFailureKind.NETWORK -> "The connection failed or timed out$page. Check the connection and retry."
            CatalogFailureKind.INVALID_PAGE -> "The server returned an unreadable response$page. Check the server log and retry."
            CatalogFailureKind.INVALID_PAGINATION -> "The server returned an incomplete set of book pages. Retry the import."
            CatalogFailureKind.CONFLICTING_CATALOG -> "The server's catalog endpoints disagree. Check the server log and retry."
        })
    }
    add("Existing books have been kept. This import is incomplete.")
}.joinToString(" ")
