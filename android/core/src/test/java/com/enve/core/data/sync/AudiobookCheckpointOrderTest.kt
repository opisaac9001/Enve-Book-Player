package com.enve.core.data.sync

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudiobookCheckpointOrderTest {
    @Test
    fun committedExternalChoiceSupersedesOlderCaptureButAllowsNextLocalIntent() = runBlocking {
        val order = AudiobookCheckpointOrder()
        val old = order.capture("a")
        val choice = order.newSequence()
        order.serialized { it.recordApplied("a", choice) }
        val fresh = order.capture("a")
        order.serialized {
            assertTrue(it.isSuperseded("a", old))
            assertFalse(it.isSuperseded("a", fresh))
            assertTrue(it.hasPendingCapture("a"))
            assertFalse(it.isSuperseded("b", old))
            it.recordApplied("a", fresh)
            assertFalse(it.hasPendingCapture("a"))
        }
    }

    @Test
    fun inFlightAndCommittedLocalIntentsProtectCatalogResponse() = runBlocking {
        val order = AudiobookCheckpointOrder()
        val captured = order.capture("a")
        val fetch = order.newSequence()
        order.serialized { assertTrue(it.hasPendingCapture("a")) }
        order.serialized { it.recordApplied("a", captured) }
        val newer = order.capture("a")
        order.serialized {
            it.recordApplied("a", newer)
            assertTrue(it.changedSince("a", fetch))
            assertFalse(it.hasPendingCapture("a"))
        }
    }

    @Test
    fun persistenceAndExternalCommitCannotInterleaveTheirStorageAndSequenceUpdate() = runBlocking {
        val order = AudiobookCheckpointOrder()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val capture = order.capture("a")
        val save = async {
            order.serialized { state ->
                entered.complete(Unit)
                release.await()
                state.recordApplied("a", capture)
            }
        }
        entered.await()
        val later = order.newSequence()
        val external = async { order.serialized { it.recordApplied("a", later) } }
        assertFalse(external.isCompleted)
        release.complete(Unit)
        save.await()
        external.await()
        order.serialized { assertTrue(it.isSuperseded("a", capture)) }
    }
}
