package com.enve.core.data.local

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingPublisherStylesTest {
    @Test
    fun pendingValueDoesNotWaitForPersistedRead() = runBlocking {
        val state = PendingPublisherStyles()
        state.begin(false)

        assertFalse(state.overlay(emptyFlow()).first())
    }

    @Test
    fun completedWriteFallsBackToCommittedValue() = runBlocking {
        val persisted = MutableStateFlow(true)
        val state = PendingPublisherStyles()
        val write = state.begin(false)

        assertFalse(state.overlay(persisted).first())
        persisted.value = false
        state.complete(write)

        assertFalse(state.overlay(persisted).first())
    }

    @Test
    fun olderWriteCannotClearNewerPendingValue() = runBlocking {
        val persisted = MutableStateFlow(false)
        val state = PendingPublisherStyles()
        val older = state.begin(false)
        val newer = state.begin(true)

        state.complete(older)

        assertTrue(state.overlay(persisted).first())
        persisted.value = true
        state.complete(newer)
        assertTrue(state.overlay(persisted).first())
    }
}
