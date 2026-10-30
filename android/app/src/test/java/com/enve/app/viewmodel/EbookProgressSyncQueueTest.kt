package com.enve.app.viewmodel

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EbookProgressSyncQueueTest {
    @Test
    fun leavingReaderFlushesOnlyTheLatestSavedPosition() = runBlocking<Unit> {
        val sent = mutableListOf<Int>()
        val queue = EbookProgressSyncQueue(this) { 0L }
        queue.submit(720_000) { sent += 1; Result.success(Unit) }
        queue.submit(720_000) { sent += 2; Result.success(Unit) }
        assertTrue(sent.isEmpty())
        queue.flush()
        queue.flush()
        assertEquals(listOf(2), sent)
    }

    @Test
    fun lateCheckpointAfterLeavingReaderIsSentImmediately() = runBlocking<Unit> {
        val sent = mutableListOf<Int>()
        val queue = EbookProgressSyncQueue(this) { 0L }
        queue.submit(720_000) { sent += 1; Result.success(Unit) }
        queue.setReaderActive(false)
        queue.flush()
        queue.submit(720_000) { sent += 2; Result.success(Unit) }
        assertEquals(listOf(1, 2), sent)
        queue.setReaderActive(true)
        queue.submit(720_000) { sent += 3; Result.success(Unit) }
        assertEquals(listOf(1, 2), sent)
        queue.flush()
        assertEquals(listOf(1, 2, 3), sent)
    }

    @Test
    fun profileRetirementDiscardsPendingNetworkWork() = runBlocking<Unit> {
        var sent = false
        val queue = EbookProgressSyncQueue(this) { 0L }
        queue.submit(720_000) { sent = true; Result.success(Unit) }
        queue.discard()
        queue.flush()
        assertEquals(false, sent)
    }

    @Test
    fun automaticModeReplacesAnOutstandingDelayedUpdate() = runBlocking<Unit> {
        val sent = mutableListOf<Int>()
        val queue = EbookProgressSyncQueue(this) { 0L }
        queue.submit(720_000) { sent += 1; Result.success(Unit) }
        queue.submit(0) { sent += 2; Result.success(Unit) }
        queue.flush()
        assertEquals(listOf(2), sent)
    }

    @Test
    fun intervalSendsWithoutAnotherPageTurn() = runBlocking<Unit> {
        val sent = CompletableDeferred<Unit>()
        val queue = EbookProgressSyncQueue(this) { 0L }
        queue.submit(20) { sent.complete(Unit); Result.success(Unit) }
        withTimeout(2_000) { sent.await() }
        queue.flush()
    }

    @Test
    fun failedUpdateRemainsAvailableForFinalFlush() = runBlocking<Unit> {
        var attempts = 0
        val queue = EbookProgressSyncQueue(this) { 0L }
        val result = queue.submit(0) {
            attempts++
            if (attempts == 1) Result.failure(IllegalStateException("offline")) else Result.success(Unit)
        }
        assertTrue(result.isFailure)
        assertTrue(queue.flush().isSuccess)
        queue.flush()
        assertEquals(2, attempts)
    }

    @Test
    fun finalFlushWaitsForAnInFlightRequestWithoutSendingItTwice() = runBlocking<Unit> {
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var sent = 0
        val queue = EbookProgressSyncQueue(this) { 0L }
        val request = async {
            queue.submit(0) {
                started.complete(Unit)
                release.await()
                sent++
                Result.success(Unit)
            }
        }
        started.await()
        val flush = async { queue.flush() }
        delay(10)
        assertEquals(false, flush.isCompleted)
        release.complete(Unit)
        request.await()
        flush.await()
        assertEquals(1, sent)
    }
}
