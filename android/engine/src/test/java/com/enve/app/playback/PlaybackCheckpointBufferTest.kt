package com.enve.app.playback

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.sync.AudiobookCheckpointOrder
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackCheckpointBufferTest {
    private val order = AudiobookCheckpointOrder()
    private val book = Book(id = "a", title = "Audio", source = BookSource.LOCAL, duration = 1000L)
    private fun point(key: String, positionMs: Long, time: Long) = PlayerProgressService.Checkpoint(
        key, "book:$key", null, positionMs, 1_000_000L, time, time, order.capture(key),
    )
    private fun saved(point: PlayerProgressService.Checkpoint) = PlayerProgressService.SaveResult.Saved(
        PlayerProgressService.PersistedPlaybackProgress(book, point.positionMs / 1000L, point.positionMs / 1_000_000f),
    )

    @Test
    fun retainedSnapshotCanFlushWithoutPlayerQueueAfterScopeCancellation() = runBlocking {
        val buffer = PlaybackCheckpointBuffer()
        val captured = buffer.retain(point("a", 42_000L, 1000L))
        val blocked = CompletableDeferred<Unit>()
        val save = launch(start = CoroutineStart.UNDISPATCHED) {
            buffer.persistCaptured(captured, beforePersist = { blocked.await() }, write = ::saved)
        }
        save.cancelAndJoin()
        val stored = mutableListOf<Long>()
        buffer.flush { stored += it.positionMs; saved(it) }
        assertEquals(listOf(42_000L), stored)
        assertTrue(buffer.pendingSnapshots().isEmpty())
        assertEquals(captured, buffer.latestSnapshot())
    }

    @Test
    fun oldAcknowledgementCannotDiscardNewerRewindOrAnotherBook() {
        val buffer = PlaybackCheckpointBuffer()
        val old = buffer.retain(point("a", 42_000L, 1000L))
        val rewind = buffer.retain(point("a", 0L, 2000L))
        val other = buffer.retain(point("b", 9_000L, 3000L))
        buffer.acknowledge(old, saved(old))
        assertEquals(listOf(rewind, other), buffer.pendingSnapshots())
        buffer.acknowledge(rewind, saved(rewind))
        assertEquals(listOf(other), buffer.pendingSnapshots())
    }

    @Test
    fun retryDoesNotAcknowledgeShutdownSnapshotButKnownSupersessionDoes() = runBlocking {
        val buffer = PlaybackCheckpointBuffer()
        val captured = buffer.retain(point("a", 0L, 1000L))
        buffer.flush { PlayerProgressService.SaveResult.Retry() }
        assertEquals(listOf(captured), buffer.pendingSnapshots())
        buffer.flush { PlayerProgressService.SaveResult.Superseded }
        assertTrue(buffer.pendingSnapshots().isEmpty())
    }

    @Test
    fun forcedSaveBlockedOnSessionMutexCannotReplaceAlreadySavedZero() = runBlocking {
        val buffer = PlaybackCheckpointBuffer()
        val sessionMutex = Mutex(locked = true)
        var stored = 120_000L
        val writer = PlaybackCheckpointWriter(order) { snapshot -> stored = snapshot.positionMs; saved(snapshot).progress }
        val old = buffer.retain(point("a", 120_000L, 1000L))
        val waiting = async(start = CoroutineStart.UNDISPATCHED) {
            buffer.persistCaptured(old, beforePersist = { sessionMutex.withLock { Unit } }) { writer.persist(it, force = true) }
        }
        val zero = buffer.retain(point("a", 0L, 500L))
        assertTrue(buffer.persistCaptured(zero) { writer.persist(it, true) } is PlayerProgressService.SaveResult.Saved)
        sessionMutex.unlock()
        assertEquals(PlayerProgressService.SaveResult.Superseded, waiting.await())
        assertEquals(0L, stored)
        assertEquals(zero, buffer.latestSnapshot())
        assertTrue(buffer.pendingSnapshots().isEmpty())
    }

    @Test
    fun blockedSessionKeepsOriginalIdentityPositionDurationAndAcknowledgement() = runBlocking {
        val buffer = PlaybackCheckpointBuffer()
        val sessionMutex = Mutex(locked = true)
        val original = buffer.retain(point("a", 120_000L, 1000L))
        val written = mutableListOf<PlayerProgressService.Checkpoint>()
        val waiting = async(start = CoroutineStart.UNDISPATCHED) {
            buffer.persistCaptured(original, beforePersist = { sessionMutex.withLock { Unit } }) {
                written += it
                saved(it)
            }
        }
        val replacement = buffer.retain(point("b", 600_000L, 2000L))
        sessionMutex.unlock()
        waiting.await()
        assertEquals(listOf(original), written)
        assertEquals(listOf(replacement), buffer.pendingSnapshots())
    }

    @Test
    fun newerRetrySurvivesOlderSaveAcknowledgementThenFlushes() = runBlocking {
        val buffer = PlaybackCheckpointBuffer()
        val old = buffer.retain(point("a", 120_000L, 1000L))
        val zero = buffer.retain(point("a", 0L, 2000L))
        buffer.persistCaptured(zero) { PlayerProgressService.SaveResult.Retry() }
        buffer.acknowledge(old, saved(old))
        assertEquals(listOf(zero), buffer.pendingSnapshots())
        buffer.flush(::saved)
        assertTrue(buffer.pendingSnapshots().isEmpty())
    }
}
