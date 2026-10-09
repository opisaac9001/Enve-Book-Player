package com.enve.app.playback

import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.toBook
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.sync.AudiobookCheckpointOrder
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackRemoteCheckpointTest {
    private val order = AudiobookCheckpointOrder()
    private val book = Book(id = "a", title = "Audio", source = BookSource.LOCAL,
        mediaType = AppMediaType.AUDIOBOOK, duration = 1000L, currentTime = 120L,
        readProgress = 0.12f, lastReadTime = 1000L)
    private var stored = book.toCachedBook()
    private var remoteWrites = 0
    private val buffer = PlaybackCheckpointBuffer()
    private val writer = PlaybackCheckpointWriter(order) { point ->
        stored = stored.copy(currentTime = point.positionMs / 1000L,
            readProgress = point.positionMs / 1_000_000f, lastReadTime = point.capturedAtMs)
        PlayerProgressService.PersistedPlaybackProgress(stored.toBook(), stored.currentTime, stored.readProgress)
    }

    private fun captureZero() = buffer.retain(PlayerProgressService.Checkpoint(
        book.uniqueKey, "book:${book.uniqueKey}", book.id, 0L, 1_000_000L,
        2000L, 2000L, order.capture(book.uniqueKey),
    ))

    private suspend fun mirror(expected: CachedBook?, sequence: Long, explicit: Boolean = false): Boolean =
        mirrorPlaybackCheckpoint(order, book.uniqueKey, expected, sequence, explicitChoice = explicit) {
            remoteWrites++
            if (stored != it) false else {
                stored = it.copy(currentTime = 250L, readProgress = 0.25f, lastReadTime = 3000L)
                true
            }
        }

    @Test
    fun automaticRemotePullCannotSupersedeBlockedZeroPersistence() = runBlocking {
        val response = CompletableDeferred<Unit>()
        val persistence = CompletableDeferred<Unit>()
        val expected = stored
        val pullSequence = order.newSequence()
        val remote = async(start = CoroutineStart.UNDISPATCHED) {
            response.await()
            mirror(expected, pullSequence)
        }
        val zero = captureZero()
        val local = async(start = CoroutineStart.UNDISPATCHED) {
            buffer.persistCaptured(zero, beforePersist = { persistence.await() }) { writer.persist(it, true) }
        }
        response.complete(Unit)
        assertFalse(remote.await())
        assertEquals(0, remoteWrites)
        assertEquals(120L, stored.currentTime)
        assertEquals(listOf(zero), buffer.pendingSnapshots())
        persistence.complete(Unit)
        assertTrue(local.await() is PlayerProgressService.SaveResult.Saved)
        assertEquals(0L, stored.currentTime)
        assertTrue(buffer.pendingSnapshots().isEmpty())
    }

    @Test
    fun automaticPullAlsoYieldsToPendingCaptureFromBeforeTheRequest() = runBlocking {
        val zero = captureZero()
        val pullSequence = order.newSequence()
        assertFalse(mirror(stored, pullSequence))
        assertEquals(0, remoteWrites)
        assertTrue(writer.persist(zero, true) is PlayerProgressService.SaveResult.Saved)
        assertEquals(0L, stored.currentTime)
    }

    @Test
    fun automaticPullCannotReplaceZeroAlreadySavedDuringTheRequest() = runBlocking {
        val expected = stored
        val pullSequence = order.newSequence()
        writer.persist(captureZero(), true)
        assertFalse(mirror(expected, pullSequence))
        assertEquals(0, remoteWrites)
        assertEquals(0L, stored.currentTime)
    }

    @Test
    fun explicitRemoteChoiceCanSupersedeEarlierPendingCaptureButAllowsNextLocalSeek() = runBlocking {
        val oldZero = captureZero()
        val choiceSequence = order.newSequence()
        assertTrue(mirror(stored, choiceSequence, explicit = true))
        assertEquals(250L, stored.currentTime)
        assertEquals(PlayerProgressService.SaveResult.Superseded,
            buffer.persistCaptured(oldZero) { writer.persist(it, true) })
        assertTrue(buffer.pendingSnapshots().isEmpty())
        assertTrue(buffer.persistCaptured(captureZero()) { writer.persist(it, true) } is PlayerProgressService.SaveResult.Saved)
        assertEquals(0L, stored.currentTime)
    }

    @Test
    fun explicitRemoteChoiceCannotSupersedeSeekCapturedAfterThatChoice() = runBlocking {
        val choiceSequence = order.newSequence()
        val zero = captureZero()
        assertFalse(mirror(stored, choiceSequence, explicit = true))
        assertEquals(0, remoteWrites)
        assertTrue(writer.persist(zero, true) is PlayerProgressService.SaveResult.Saved)
        assertEquals(0L, stored.currentTime)
    }

    @Test
    fun failedRemoteCommitDoesNotSupersedeEarlierPendingLocalCapture() = runBlocking {
        val zero = captureZero()
        val choiceSequence = order.newSequence()
        assertFalse(mirrorPlaybackCheckpoint(order, book.uniqueKey, stored, choiceSequence, explicitChoice = true) { false })
        assertTrue(writer.persist(zero, true) is PlayerProgressService.SaveResult.Saved)
        assertEquals(0L, stored.currentTime)
    }

    @Test
    fun disabledSyncDoesNotMirrorOrSupersedeLocalCapture() = runBlocking {
        val zero = captureZero()
        val choiceSequence = order.newSequence()
        assertFalse(mirrorPlaybackCheckpoint(order, book.uniqueKey, stored, choiceSequence,
            explicitChoice = true, isEnabled = { false }) { error("Unexpected write") })
        assertTrue(writer.persist(zero, true) is PlayerProgressService.SaveResult.Saved)
    }

    @Test
    fun absentCachedRowDoesNotRecordADurableRemoteCommit() = runBlocking {
        val zero = captureZero()
        val choiceSequence = order.newSequence()
        assertTrue(mirror(null, choiceSequence, explicit = true))
        assertEquals(0, remoteWrites)
        assertTrue(writer.persist(zero, true) is PlayerProgressService.SaveResult.Saved)
    }
}
