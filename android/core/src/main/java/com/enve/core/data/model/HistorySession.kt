package com.enve.core.data.model

import kotlinx.serialization.Serializable

@Serializable
enum class HistorySessionOrigin {
    LOCAL,
    BOOKORBIT,
}

@Serializable
data class HistorySession(
    val id: String,
    val bookId: String,
    val bookKey: String,
    val connectionId: String? = null,
    val source: BookSource,
    val mediaType: AppMediaType,
    val startTimeMs: Long,
    val endTimeMs: Long,
    val activeDurationSeconds: Long,
    val startProgress: Float? = null,
    val endProgress: Float? = null,
    val pagesRead: Int? = null,
    val origin: HistorySessionOrigin = HistorySessionOrigin.LOCAL,
)
