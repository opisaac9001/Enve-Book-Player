package com.enve.core.data.provider

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import java.security.MessageDigest
import kotlinx.serialization.Serializable

@Serializable
enum class CatalogRejectionReason {
    MISSING_ID, INVALID_ID, INVALID_RECORD, WRONG_LIBRARY, MISSING_INVENTORY,
}

@Serializable
enum class CatalogFailureKind {
    HTTP, ACCESS_DENIED, NETWORK, INVALID_PAGE, CONFLICTING_CATALOG, INVALID_PAGINATION,
}

@Serializable
enum class CatalogImportStage { BOOKS, FORMATS, LEGACY }

@Serializable
data class CatalogFailure(
    val kind: CatalogFailureKind,
    val stage: CatalogImportStage,
    val page: Int? = null,
    val httpStatus: Int? = null,
)

@Serializable
data class CatalogImportReport(
    val source: BookSource = BookSource.GRIMMORY,
    val acceptedCount: Int = 0,
    val rejections: Map<CatalogRejectionReason, Int> = emptyMap(),
    val failures: List<CatalogFailure> = emptyList(),
) {
    val rejectedCount: Int get() = rejections.values.sum()
    val isComplete: Boolean get() = rejections.isEmpty() && failures.isEmpty()

    fun merge(other: CatalogImportReport): CatalogImportReport = copy(
        acceptedCount = acceptedCount + other.acceptedCount,
        rejections = (rejections.keys + other.rejections.keys).associateWith {
            rejections.getOrDefault(it, 0) + other.rejections.getOrDefault(it, 0)
        },
        failures = (failures + other.failures).distinct(),
    )

    fun rejecting(reason: CatalogRejectionReason, count: Int = 1): CatalogImportReport =
        if (count <= 0) this else merge(CatalogImportReport(source, rejections = mapOf(reason to count)))
}

class CatalogImportException(
    val books: List<Book>,
    val reports: List<CatalogImportReport>,
    val issues: List<CatalogImportIssue> = emptyList(),
) : Exception("Library import incomplete")

@Serializable
data class CatalogImportIssue(
    val connectionKey: String,
    val scopeKey: String,
    val report: CatalogImportReport,
)

fun catalogImportConnectionKey(connectionId: String?): String = catalogImportKey(connectionId.orEmpty())

fun catalogImportScopeKey(connectionId: String?, libraryId: String?): String =
    catalogImportKey("${connectionId.orEmpty()}::${libraryId?.substringAfter("::").orEmpty()}")

private fun catalogImportKey(value: String): String = MessageDigest.getInstance("SHA-256")
    .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
