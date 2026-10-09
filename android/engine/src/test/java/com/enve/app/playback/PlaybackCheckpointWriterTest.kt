package com.enve.app.playback

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.sync.AudiobookCheckpointOrder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackCheckpointWriterTest {
    private val order = AudiobookCheckpointOrder()
    private var stored = Book(id = "a", title = "Audio", source = BookSource.AUDIOBOOKSHELF,
        duration = 1000L, currentTime = 120L, lastReadTime = 9_000_000L)
    private val writer = PlaybackCheckpointWriter(order) { point ->
        stored = stored.copy(currentTime = point.positionMs / 1000L,
            readProgress = point.positionMs / 1_000_000f, lastReadTime = point.capturedAtMs)
        PlayerProgressService.PersistedPlaybackProgress(stored, stored.currentTime, stored.readProgress)
    }

    private fun point(positionMs: Long, wall: Long, elapsed: Long) = PlayerProgressService.Checkpoint(
        "a", "book:a", null, positionMs, 1_000_000L, wall, elapsed, order.capture("a"),
    )

    @Test
    fun futureServerTimestampCannotRejectFreshZeroOrShutdownCheckpoint() = runBlocking {
        val zero = point(0L, 1000L, 1000L)
        assertTrue(writer.persist(zero, force = true) is PlayerProgressService.SaveResult.Saved)
        assertEquals(0L, stored.currentTime)
        assertEquals(1000L, stored.lastReadTime)
        val shutdown = point(42_000L, 1100L, 1100L)
        assertTrue(writer.persist(shutdown, force = true) is PlayerProgressService.SaveResult.Saved)
        assertEquals(42L, stored.currentTime)
    }

    @Test
    fun clockRollbackDoesNotReverseOrderingOrExtendElapsedThrottle() = runBlocking {
        assertTrue(writer.persist(point(120_000L, 10_000L, 1000L), false) is PlayerProgressService.SaveResult.Saved)
        assertTrue(writer.persist(point(240_000L, 500L, 2000L), false) is PlayerProgressService.SaveResult.Retry)
        assertTrue(writer.persist(point(240_000L, 400L, 6000L), false) is PlayerProgressService.SaveResult.Saved)
        assertEquals(240L, stored.currentTime)
        assertEquals(400L, stored.lastReadTime)
        assertTrue(writer.persist(point(0L, 300L, 6100L), true) is PlayerProgressService.SaveResult.Saved)
        assertEquals(0L, stored.currentTime)
    }

    @Test
    fun delayedCaptureCannotBecomeNewerByBeingPersistedLater() = runBlocking {
        val old = point(120_000L, 10_000L, 1000L)
        val rewind = point(0L, 500L, 2000L)
        writer.persist(rewind, true)
        assertEquals(PlayerProgressService.SaveResult.Superseded, writer.persist(old, true))
        assertEquals(0L, stored.currentTime)
    }

    @Test
    fun unavailableStorageAndFailedWritesRemainRetryable() = runBlocking {
        val point = point(0L, 1000L, 1000L)
        var available = false
        val flaky = PlaybackCheckpointWriter(order) {
            if (!available) null else PlayerProgressService.PersistedPlaybackProgress(stored, 0L, 0f)
        }
        assertTrue(flaky.persist(point, true) is PlayerProgressService.SaveResult.Retry)
        order.serialized { assertTrue(it.hasPendingCapture("a")) }
        available = true
        assertTrue(flaky.persist(point, true) is PlayerProgressService.SaveResult.Saved)
        val failure = PlaybackCheckpointWriter(order) { throw IllegalStateException("Storage unavailable") }
        val failed = failure.persist(point(10_000L, 2000L, 2000L), true)
        assertTrue(failed is PlayerProgressService.SaveResult.Retry && failed.error is IllegalStateException)
    }

    @Test(expected = CancellationException::class)
    fun cancellationDoesNotBecomeAnAcknowledgedFailure() = runBlocking {
        val cancelled = PlaybackCheckpointWriter(order) { throw CancellationException("Stopped") }
        cancelled.persist(point(0L, 1000L, 1000L), true)
        Unit
    }
}
