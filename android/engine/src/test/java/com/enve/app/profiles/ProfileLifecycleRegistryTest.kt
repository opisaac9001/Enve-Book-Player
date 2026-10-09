package com.enve.app.profiles

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ProfileLifecycleRegistryTest {
    @Test
    fun retirementAwaitsOutgoingCheckpointAndLeavesOtherProfilesRunning() = runBlocking {
        val registry = ProfileLifecycleRegistry()
        val entered = CompletableDeferred<Unit>()
        val checkpoint = CompletableDeferred<Unit>()
        val events = mutableListOf<String>()
        registry.register("outgoing") {
            entered.complete(Unit)
            checkpoint.await()
            events += "saved"
        }
        registry.register("destination") { events += "destination closed" }
        val switch = async {
            registry.checkpointAndClose("outgoing")
            events += "published"
        }
        entered.await()
        yield()
        assertFalse(switch.isCompleted)
        assertEquals(emptyList<String>(), events)
        checkpoint.complete(Unit)
        switch.await()
        assertEquals(listOf("saved", "published"), events)
    }

    @Test
    fun failedCheckpointPreventsPublication() = runBlocking {
        val registry = ProfileLifecycleRegistry()
        val events = mutableListOf<String>()
        registry.register("outgoing") { error("Checkpoint failed") }
        try {
            registry.checkpointAndClose("outgoing")
            events += "published"
        } catch (_: IllegalStateException) {
            events += "failed"
        }
        assertEquals(listOf("failed"), events)
    }
}
