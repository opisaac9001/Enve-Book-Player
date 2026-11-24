package com.enve.engine.readwise

import kotlinx.coroutines.flow.StateFlow

sealed interface ReadwiseExportScope {
    data object AllBooks : ReadwiseExportScope
    data class Book(val bookId: String, val connectionId: String?) : ReadwiseExportScope
}

enum class ReadwiseFailure { NOT_CONNECTED, INVALID_TOKEN, RATE_LIMITED, REJECTED, SERVER, NETWORK, STORAGE }

data class ReadwisePreviewHighlight(
    val bookTitle: String?,
    val bookAuthor: String?,
    val text: String,
    val note: String?,
)

data class ReadwiseExportPreview(
    val scope: ReadwiseExportScope,
    val bookCount: Int,
    val newCount: Int,
    val changedCount: Int,
    val alreadySentCount: Int,
    val excludedCount: Int,
    val samples: List<ReadwisePreviewHighlight>,
) {
    val readyCount: Int get() = newCount + changedCount
}

data class ReadwiseExportProgress(val sent: Int, val total: Int)

data class ReadwiseExportResult(
    val sentCount: Int,
    val unsentCount: Int,
    val failure: ReadwiseFailure?,
    val retryAfterSeconds: Long? = null,
)

interface ReadwiseFacade {
    val isConnected: StateFlow<Boolean>

    suspend fun connect(token: String): ReadwiseFailure?

    suspend fun validate(): ReadwiseFailure?

    fun disconnect()

    suspend fun preview(scope: ReadwiseExportScope): ReadwiseExportPreview

    suspend fun export(
        scope: ReadwiseExportScope,
        onProgress: (ReadwiseExportProgress) -> Unit = {},
    ): ReadwiseExportResult
}
