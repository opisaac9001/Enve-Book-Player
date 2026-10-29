package com.enve.engine.listeningposition

import com.enve.core.data.model.Book
import com.enve.core.listeningposition.ListeningPositionPayload
import com.enve.core.listeningposition.SharedReadingLocation

data class ListeningPositionCandidate(
    val book: Book,
    val score: Double,
    val hasCredibleIdentity: Boolean,
    val warnings: List<String>,
    val canApply: Boolean,
    val sourceLabel: String? = null,
)

enum class ListeningPositionServerStatus { SAVED, QUEUED, NO_SERVER, SYNC_DISABLED, UNKNOWN_LENGTH }

data class ListeningPositionApplyResult(val book: Book, val positionMilliseconds: Long, val server: ListeningPositionServerStatus, val readingLocation: SharedReadingLocation? = null)

interface ListeningPositionFacade {
    fun share(book: Book): ListeningPositionPayload?
    suspend fun suggestions(payload: ListeningPositionPayload): List<ListeningPositionCandidate>
    suspend fun search(payload: ListeningPositionPayload, query: String): List<ListeningPositionCandidate>
    suspend fun apply(payload: ListeningPositionPayload, book: Book): ListeningPositionApplyResult
}
