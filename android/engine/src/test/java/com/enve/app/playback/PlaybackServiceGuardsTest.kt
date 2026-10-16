package com.enve.app.playback

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PlaybackServiceGuardsTest {
    @Test
    fun browserHelperWaitEndsWhenStartupNeverCompletes() = runBlocking {
        val ready = CompletableDeferred<String?>()

        assertNull(ready.awaitReady(timeoutMs = 50L))
        assertFalse(ready.isCompleted)
    }

    @Test
    fun browserHelperWaitReturnsCompletedHelper() = runBlocking {
        val helper = "helper"
        val ready = CompletableDeferred<String?>().apply { complete(helper) }

        assertSame(helper, ready.awaitReady(timeoutMs = 50L))
    }

    @Test
    fun browserHelperWaitReportsFailedStartup() = runBlocking {
        val ready = CompletableDeferred<String?>().apply { complete(null) }

        assertNull(ready.awaitReady(timeoutMs = 50L))
    }

    @Test
    fun checkpointPositionAddsKnownEarlierTracks() {
        assertEquals(
            150_000L,
            knownAbsolutePositionMs(previousItemDurationsMs = listOf(60_000L, 60_000L), currentPositionMs = 30_000L),
        )
    }

    @Test
    fun checkpointPositionOnFirstTrackIsTheTrackPosition() {
        assertEquals(42_000L, knownAbsolutePositionMs(previousItemDurationsMs = emptyList(), currentPositionMs = 42_000L))
    }

    @Test
    fun checkpointPositionIsWithheldWhileEarlierTrackDurationIsUnknown() {
        assertNull(knownAbsolutePositionMs(previousItemDurationsMs = listOf(60_000L, 0L), currentPositionMs = 30_000L))
    }

    @Test
    fun checkpointPositionNeverGoesNegative() {
        assertEquals(0L, knownAbsolutePositionMs(previousItemDurationsMs = emptyList(), currentPositionMs = -5L))
    }

    @Test
    fun newerPlaybackRequestSupersedesOlderCompletion() {
        val gate = PlaybackRequestGate()
        val first = gate.begin()
        val second = gate.begin()

        assertFalse(gate.isCurrent(first))
        assertTrue(gate.isCurrent(second))
    }

    @Test
    fun sequentialPlaybackRequestsStayCurrentUntilReplaced() {
        val gate = PlaybackRequestGate()
        val first = gate.begin()
        assertTrue(gate.isCurrent(first))

        val second = gate.begin()
        assertTrue(gate.isCurrent(second))
        assertFalse(gate.isCurrent(first))
    }

    @Test
    fun observedAppendIsRejectedOnceANewerSelectionBegins() {
        val gate = PlaybackRequestGate()
        val append = gate.current()
        assertTrue(gate.isCurrent(append))

        gate.begin()

        assertSuperseded { gate.ensureCurrent(append) }
    }

    @Test
    fun olderAutoAddCannotAdoptAfterNewerSelection() = runBlocking {
        val gate = PlaybackRequestGate()
        val adopted = mutableListOf<String>()
        val olderAdd = gate.begin()
        val newerSet = gate.begin()

        assertSuperseded { gate.adopt(olderAdd) { adopted += "older" } }
        gate.adopt(newerSet) { adopted += "newer" }

        assertEquals(listOf("newer"), adopted)
    }

    @Test
    fun inFlightAdoptionStopsAtNextStepAndNewerAdoptionRunsAfterIt() = runBlocking {
        val gate = PlaybackRequestGate()
        val steps = mutableListOf<String>()
        val olderStarted = CompletableDeferred<Unit>()
        val releaseOlder = CompletableDeferred<Unit>()
        val older = gate.begin()

        val olderAdoption = async(start = CoroutineStart.UNDISPATCHED) {
            runCatching {
                gate.adopt(older) {
                    steps += "older:player"
                    olderStarted.complete(Unit)
                    releaseOlder.await()
                    gate.ensureCurrent(older)
                    steps += "older:session"
                }
            }
        }
        olderStarted.await()

        val newer = gate.begin()
        val newerAdoption = async(start = CoroutineStart.UNDISPATCHED) {
            gate.adopt(newer) {
                gate.ensureCurrent(newer)
                steps += "newer:player"
                steps += "newer:session"
            }
        }
        yield()
        assertEquals(listOf("older:player"), steps)

        releaseOlder.complete(Unit)
        assertTrue(olderAdoption.await().exceptionOrNull() is IllegalStateException)
        newerAdoption.await()

        assertEquals(listOf("older:player", "newer:player", "newer:session"), steps)
    }

    @Test
    fun adoptionQueuedBehindLockIsDroppedWhenSupersededWhileWaiting() = runBlocking {
        val gate = PlaybackRequestGate()
        val adopted = mutableListOf<String>()
        val releaseFirst = CompletableDeferred<Unit>()
        val first = gate.begin()
        val firstAdoption = async(start = CoroutineStart.UNDISPATCHED) {
            gate.adopt(first) {
                releaseFirst.await()
                adopted += "first"
            }
        }

        val second = gate.begin()
        val secondAdoption = async(start = CoroutineStart.UNDISPATCHED) {
            runCatching { gate.adopt(second) { adopted += "second" } }
        }
        val third = gate.begin()

        releaseFirst.complete(Unit)
        firstAdoption.await()
        assertTrue(secondAdoption.await().exceptionOrNull() is IllegalStateException)
        gate.adopt(third) { adopted += "third" }

        assertEquals(listOf("first", "third"), adopted)
    }

    private inline fun assertSuperseded(block: () -> Unit) {
        try {
            block()
            fail("Expected the playback request to be superseded")
        } catch (expected: IllegalStateException) {
        }
    }

    @Test
    fun unknownAbsolutePositionKeepsLastKnownSessionPosition() {
        val session = activeSession(positionSec = 600L, durationSec = 3_600L)
        assertFalse(session.observe(positionSec = 610L, durationSec = 3_600L, nowMs = 10_000L, wasPlaying = true))

        assertFalse(session.observe(positionSec = null, durationSec = 60L, nowMs = 20_000L, wasPlaying = true))

        assertEquals(610L, session.lastPositionSec)
        assertEquals(3_600L, session.durationSec)
        assertEquals(10_000L, session.lastTickAtMs)
    }

    @Test
    fun knownPositionAfterUnknownGapIsMeasuredFromLastKnownTick() {
        val session = activeSession(positionSec = 600L, durationSec = 3_600L)
        session.observe(positionSec = 610L, durationSec = 3_600L, nowMs = 10_000L, wasPlaying = true)
        session.observe(positionSec = null, durationSec = 60L, nowMs = 20_000L, wasPlaying = true)

        assertFalse(session.observe(positionSec = 640L, durationSec = 3_600L, nowMs = 40_000L, wasPlaying = true))
        assertEquals(640L, session.lastPositionSec)
    }

    @Test
    fun knownPositionStillDetectsSeek() {
        val session = activeSession(positionSec = 600L, durationSec = 3_600L)
        session.observe(positionSec = 610L, durationSec = 3_600L, nowMs = 10_000L, wasPlaying = true)

        assertTrue(session.observe(positionSec = 100L, durationSec = 3_600L, nowMs = 11_000L, wasPlaying = true))
        assertEquals(100L, session.lastPositionSec)
    }

    private fun activeSession(positionSec: Long, durationSec: Long) = PlayerSessionService.ActiveSession(
        book = Book(id = "a", title = "Audio", source = BookSource.AUDIOBOOKSHELF),
        bookKey = "abs:a",
        startedAtMs = 0L,
        durationSec = durationSec,
        startPositionSec = positionSec,
        lastPositionSec = positionSec,
    )
}
