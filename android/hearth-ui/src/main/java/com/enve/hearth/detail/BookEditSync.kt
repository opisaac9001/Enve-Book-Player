package com.enve.hearth.detail

import com.enve.core.data.local.PendingBookMutation
import com.enve.core.data.local.PendingBookMutationFailure
import com.enve.engine.library.BookEditOutcome

internal data class BookEditSyncStatus(
    val message: String,
    val isError: Boolean,
    val canRetry: Boolean,
    val canDiscard: Boolean,
)

internal fun bookEditSyncStatus(mutation: PendingBookMutation, sourceName: String): BookEditSyncStatus =
    when (mutation.failure) {
        null -> BookEditSyncStatus(
            message = "Waiting to sync with $sourceName",
            isError = false,
            canRetry = false,
            canDiscard = false,
        )
        PendingBookMutationFailure.TRANSIENT -> BookEditSyncStatus(
            message = "Waiting to sync. $sourceName couldn't be reached.",
            isError = false,
            canRetry = true,
            canDiscard = false,
        )
        PendingBookMutationFailure.AUTH -> BookEditSyncStatus(
            message = "Not synced. Sign in to $sourceName again, then retry.",
            isError = true,
            canRetry = true,
            canDiscard = true,
        )
        PendingBookMutationFailure.REJECTED -> BookEditSyncStatus(
            message = "Not synced. $sourceName refused this change.",
            isError = true,
            canRetry = true,
            canDiscard = true,
        )
        PendingBookMutationFailure.UNAVAILABLE -> BookEditSyncStatus(
            message = "Not synced. This $sourceName account or source isn't available on this device.",
            isError = true,
            canRetry = true,
            canDiscard = true,
        )
    }

internal fun bookEditNotice(subject: String, sourceName: String, outcome: BookEditOutcome): String = when (outcome) {
    BookEditOutcome.SYNCED -> "$subject saved to $sourceName."
    BookEditOutcome.WAITING -> "$subject saved here. Waiting to sync with $sourceName."
    BookEditOutcome.LOCAL_ONLY -> "$subject saved on this device."
    BookEditOutcome.NEEDS_SIGN_IN -> "$subject saved here. Sign in to $sourceName again to sync it."
    BookEditOutcome.REJECTED -> "$sourceName refused the change. It's kept here so you can retry or discard it."
    BookEditOutcome.UNAVAILABLE -> "$subject saved here, but its $sourceName source isn't available."
    BookEditOutcome.NOT_SAVED -> "Couldn't save the ${subject.lowercase()}."
}

internal fun readStatusLabel(status: String): String = when (status.uppercase()) {
    "UNREAD" -> "Unread"
    "WANT_TO_READ" -> "Want to read"
    "READING" -> "Reading"
    "ON_HOLD" -> "On hold"
    "REREADING" -> "Rereading"
    "READ" -> "Read"
    "SKIMMED" -> "Skimmed"
    "ABANDONED" -> "Abandoned"
    else -> status.lowercase().replace('_', ' ').replaceFirstChar(Char::uppercaseChar)
}

internal val FINISHED_READ_STATUSES = setOf("READ", "SKIMMED")
