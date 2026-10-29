package com.enve.app.viewmodel

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.ReaderEngineKind
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.util.Url
import org.readium.r2.shared.util.mediatype.MediaType

@RunWith(AndroidJUnit4::class)
class FinalReadingCaptureTest {
    @Test
    fun closeAwaitsStartedCaptureAfterUiScopeIsCancelled() = runBlocking {
        val uiScope = CoroutineScope(coroutineContext + SupervisorJob())
        val appScope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val state = heldAt(0.6)
            val generation = state.generation
            val answer = CompletableDeferred<Unit>()
            var captureStarts = 0
            var persisted: Double? = null
            val finalCapture = appScope.launch(start = CoroutineStart.UNDISPATCHED) {
                captureStarts++
                answer.await()
                state.hold(capture(0.2), generation)
            }
            val close = appScope.launch(start = CoroutineStart.UNDISPATCHED) {
                awaitStartedReadingCapture(finalCapture)
                state.invalidate()
                persisted = state.current()?.checkpoint?.totalProgression
            }
            uiScope.cancel()
            assertTrue(close.isActive)
            assertTrue(finalCapture.isActive)
            assertEquals(generation, state.generation)
            answer.complete(Unit)
            withTimeout(1_500L) { close.join() }
            assertEquals(0.2, persisted!!, 0.0)
            assertEquals(1, captureStarts)
            assertFalse(finalCapture.isCancelled)
        } finally {
            uiScope.cancel()
            appScope.cancel()
        }
    }

    @Test
    fun nonresponsiveCaptureDoesNotHoldCloseOrEraseConfirmedPosition() = runBlocking {
        val appScope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val state = heldAt(0.6)
            var captureStarts = 0
            val finalCapture = appScope.launch(start = CoroutineStart.UNDISPATCHED) {
                captureStarts++
                awaitCancellation()
            }
            withTimeout(1_500L) { awaitStartedReadingCapture(finalCapture) }
            state.invalidate()
            assertTrue(finalCapture.isCancelled)
            assertEquals(0.6, state.current()!!.checkpoint.totalProgression!!, 0.0)
            assertEquals(1, captureStarts)
        } finally { appScope.cancel() }
    }

    @Test
    fun awaitingCaptureCannotUndoANewerNavigation() = runBlocking {
        val appScope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val state = heldAt(0.6)
            val generation = state.generation
            val answer = CompletableDeferred<Unit>()
            var oldAccepted = true
            val finalCapture = appScope.launch(start = CoroutineStart.UNDISPATCHED) {
                answer.await()
                oldAccepted = state.hold(capture(0.4), generation)
            }
            val close = appScope.launch(start = CoroutineStart.UNDISPATCHED) {
                awaitStartedReadingCapture(finalCapture)
                state.invalidate()
            }
            val current = capture(0.2)
            assertTrue(state.hold(current, state.observe(current.locator)))
            answer.complete(Unit)
            withTimeout(1_500L) { close.join() }
            assertFalse(oldAccepted)
            assertEquals(current, state.current())
        } finally { appScope.cancel() }
    }

    private fun heldAt(progression: Double): HeldReadingPosition = HeldReadingPosition().apply {
        val initial = capture(progression)
        check(hold(initial, observe(initial.locator)))
    }

    private fun capture(progression: Double): ReadiumCheckpointCapture {
        val locator = Locator(Url("chapter.xhtml")!!, MediaType.XHTML,
            locations = Locator.Locations(totalProgression = progression))
        return ReadiumCheckpointCapture(locator, EpubBridgeCheckpoint(
            publicationSha256 = "fixture", writerEpoch = 1, revision = 0, observedAt = 1,
            sourceEngine = ReaderEngineKind.READIUM, href = "chapter.xhtml", totalProgression = progression))
    }
}
