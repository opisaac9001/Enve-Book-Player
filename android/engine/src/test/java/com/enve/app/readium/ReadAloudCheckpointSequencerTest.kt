package com.enve.app.readium

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadAloudCheckpointSequencerTest {

    @Test
    fun flushCoalescesToNewestRevision() = runBlocking {
        val writes = mutableListOf<String>()
        val sequencer = ReadAloudCheckpointSequencer<String> { writes += it }
        val token = token("book", "session")
        sequencer.beginSession(token)

        assertTrue(sequencer.offer(token, 1L, "old"))
        assertTrue(sequencer.offer(token, 2L, "new"))
        assertFalse(sequencer.offer(token, 1L, "stale revision"))
        sequencer.flush(token.bookKey)

        assertEquals(listOf("new"), writes)
    }

    @Test
    fun startingNewSessionDoesNotDropPendingCheckpoint() = runBlocking {
        val writes = mutableListOf<String>()
        val sequencer = ReadAloudCheckpointSequencer<String> { writes += it }
        val oldToken = token("book", "old")
        val newToken = token("book", "new")
        sequencer.beginSession(oldToken)
        sequencer.offer(oldToken, 1L, "pending from old session")

        sequencer.beginSession(newToken)
        sequencer.flush(newToken.bookKey)

        assertEquals(listOf("pending from old session"), writes)
    }

    @Test
    fun callbacksFromReplacedSessionAreRejected() = runBlocking {
        val writes = mutableListOf<String>()
        val sequencer = ReadAloudCheckpointSequencer<String> { writes += it }
        val oldToken = token("book", "old")
        val newToken = token("book", "new")
        sequencer.beginSession(oldToken)
        sequencer.beginSession(newToken)

        assertFalse(sequencer.offer(oldToken, 1L, "stale session"))
        assertTrue(sequencer.offer(newToken, 1L, "active session"))
        sequencer.flush(newToken.bookKey)

        assertEquals(listOf("active session"), writes)
    }

    @Test
    fun checkpointOfferedDuringWriteIsPersistedAfterIt() = runBlocking {
        val writes = mutableListOf<String>()
        val firstWriteStarted = CompletableDeferred<Unit>()
        val releaseFirstWrite = CompletableDeferred<Unit>()
        val sequencer = ReadAloudCheckpointSequencer<String> { value ->
            writes += value
            if (value == "first") {
                firstWriteStarted.complete(Unit)
                releaseFirstWrite.await()
            }
        }
        val token = token("book", "session")
        sequencer.beginSession(token)
        sequencer.offer(token, 1L, "first")

        val flush = async { sequencer.flush(token.bookKey) }
        firstWriteStarted.await()
        sequencer.offer(token, 2L, "second")
        releaseFirstWrite.complete(Unit)
        flush.await()

        assertEquals(listOf("first", "second"), writes)
    }

    @Test
    fun differentBooksKeepIndependentPendingCheckpoints() = runBlocking {
        val writes = mutableListOf<String>()
        val sequencer = ReadAloudCheckpointSequencer<String> { writes += it }
        val first = token("first", "session-1")
        val second = token("second", "session-2")
        sequencer.beginSession(first)
        sequencer.beginSession(second)
        sequencer.offer(first, 1L, "first book")
        sequencer.offer(second, 1L, "second book")

        sequencer.flush(second.bookKey)
        sequencer.flush(first.bookKey)

        assertEquals(listOf("second book", "first book"), writes)
    }

    @Test
    fun pendingBookKeysOnlyReturnsUnpersistedBooks() = runBlocking {
        val sequencer = ReadAloudCheckpointSequencer<String> { }
        val pending = token("pending", "session-1")
        val persisted = token("persisted", "session-2")
        sequencer.beginSession(pending)
        sequencer.beginSession(persisted)
        sequencer.offer(pending, 1L, "pending")
        sequencer.offer(persisted, 1L, "persisted")
        sequencer.flush(persisted.bookKey)

        assertEquals(listOf(pending.bookKey), sequencer.pendingBookKeys())
    }

    private fun token(book: String, session: String) = ReadAloudCheckpointToken(
        bookKey = book,
        sessionId = session,
    )
}
