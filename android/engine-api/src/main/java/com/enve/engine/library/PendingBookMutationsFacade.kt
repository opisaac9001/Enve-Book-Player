package com.enve.engine.library

import com.enve.core.data.local.PendingBookMutation
import com.enve.core.data.model.Book
import kotlinx.coroutines.flow.StateFlow

enum class BookEditOutcome {
    SYNCED,
    WAITING,
    LOCAL_ONLY,
    NEEDS_SIGN_IN,
    REJECTED,
    UNAVAILABLE,
    NOT_SAVED,
    ;

    val accepted: Boolean get() = this == SYNCED || this == WAITING || this == LOCAL_ONLY
}

interface PendingBookMutationsFacade {
    val pending: StateFlow<List<PendingBookMutation>>

    fun readStatusOptions(book: Book): List<String>

    suspend fun setPersonalRating(book: Book, rating: Int): BookEditOutcome

    suspend fun setReadStatus(book: Book, status: String): BookEditOutcome

    suspend fun retry(mutation: PendingBookMutation): BookEditOutcome

    suspend fun discard(mutation: PendingBookMutation)

    fun replayOnForeground()
}
