package com.enve.hearth.detail

import com.enve.core.data.local.PendingBookMutation
import com.enve.core.data.local.PendingBookMutationFailure
import com.enve.core.data.local.PendingBookMutationKind
import com.enve.engine.library.BookEditOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BookEditSyncTest {
    private fun mutation(failure: PendingBookMutationFailure?) = PendingBookMutation(
        source = "BOOKORBIT",
        connectionKey = "connection-a",
        accountKey = "http://localhost|reader",
        bookId = "101",
        kind = PendingBookMutationKind.RATING,
        value = "4",
        revision = 3L,
        createdAt = 1L,
        attempts = if (failure == null) 0 else 1,
        failure = failure,
    )

    @Test
    fun unsentEditReadsAsWaitingNotSaved() {
        val status = bookEditSyncStatus(mutation(null), "BookOrbit")

        assertEquals("Waiting to sync with BookOrbit", status.message)
        assertFalse(status.isError)
        assertFalse(status.canRetry)
    }

    @Test
    fun transientFailureStaysWaitingAndOffersRetryWithoutDiscard() {
        val status = bookEditSyncStatus(mutation(PendingBookMutationFailure.TRANSIENT), "BookOrbit")

        assertTrue(status.message.startsWith("Waiting to sync"))
        assertFalse(status.isError)
        assertTrue(status.canRetry)
        assertFalse(status.canDiscard)
    }

    @Test
    fun authAndRejectionAreErrorsThatKeepTheEditRecoverable() {
        listOf(
            PendingBookMutationFailure.AUTH,
            PendingBookMutationFailure.REJECTED,
            PendingBookMutationFailure.UNAVAILABLE,
        ).forEach { failure ->
            val status = bookEditSyncStatus(mutation(failure), "BookOrbit")
            assertTrue(status.isError)
            assertTrue(status.message.startsWith("Not synced"))
            assertTrue(status.canRetry)
            assertTrue(status.canDiscard)
        }
    }

    @Test
    fun onlyAConfirmedServerWriteIsReportedAsSavedToTheSource() {
        assertEquals("Rating saved to BookOrbit.", bookEditNotice("Rating", "BookOrbit", BookEditOutcome.SYNCED))
        BookEditOutcome.entries.filter { it != BookEditOutcome.SYNCED }.forEach { outcome ->
            assertFalse(bookEditNotice("Rating", "BookOrbit", outcome).contains("saved to BookOrbit"))
        }
        assertEquals("Couldn't save the reading status.", bookEditNotice("Reading status", "BookOrbit", BookEditOutcome.NOT_SAVED))
    }

    @Test
    fun readStatusesHaveReadableLabels() {
        assertEquals("Want to read", readStatusLabel("WANT_TO_READ"))
        assertEquals("On hold", readStatusLabel("on_hold"))
        assertEquals("Did not finish", readStatusLabel("DID_NOT_FINISH"))
    }
}
