package com.enve.app.ui.screens.reader

import com.enve.core.data.local.ReaderPageTurnStyle
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderPageCurlTest {
    @Test
    fun curlOnlyRunsWhenChosenAndNothingSuppressesIt() {
        fun curl(
            style: ReaderPageTurnStyle = ReaderPageTurnStyle.CURL,
            animated: Boolean = true,
            scroll: Boolean = false,
            reduceMotion: Boolean = false,
            animators: Boolean = true,
            eink: Boolean = false,
        ) = ReaderPageCurlPolicy.shouldCurl(style, animated, scroll, reduceMotion, animators, eink)

        assertTrue(curl())
        assertFalse(curl(style = ReaderPageTurnStyle.STANDARD))
        assertFalse(curl(animated = false))
        assertFalse(curl(scroll = true))
        assertFalse(curl(reduceMotion = true))
        assertFalse(curl(animators = false))
        assertFalse(curl(eink = true))
    }

    @Test
    fun disabledCurlTurnsImmediatelyWithoutCapturing() = runBlocking {
        val events = mutableListOf<String>()
        runner(events).turn(forward = true, curl = false, awaitTurn = { { events += "settled" } }, perform = { events += "perform" })

        assertEquals(listOf("perform"), events)
    }

    @Test
    fun curlCapturesBeforeTurningAndReleasesTheSnapshotAfterAnimating() = runBlocking {
        val events = mutableListOf<String>()
        val runner = runner(events)
        runner.turn(
            forward = false,
            curl = true,
            awaitTurn = { events += "baseline"; { events += "settled" } },
            perform = { events += "perform" },
        )
        awaitEvent(events, "release:snapshot")

        assertEquals(
            listOf("capture", "present:snapshot:false", "baseline", "perform", "settled", "animate", "release:snapshot"),
            events,
        )
        assertFalse(runner.active)
    }

    @Test
    fun rendererThatNeverSettlesSkipsTheAnimationButStillReleases() = runBlocking {
        val events = mutableListOf<String>()
        runner(events).turn(true, true, awaitTurn = { { awaitCancellation() } }, perform = { events += "perform" })
        awaitEvent(events, "release:snapshot")

        assertEquals(listOf("capture", "present:snapshot:true", "perform", "release:snapshot"), events)
    }

    @Test
    fun failedCaptureFallsBackToAPlainTurn() = runBlocking {
        val events = mutableListOf<String>()
        runner(events, capture = { events += "capture"; null })
            .turn(true, true, awaitTurn = { { events += "settled" } }, perform = { events += "perform" })
        awaitEvent(events, "perform")

        assertEquals(listOf("capture", "perform"), events)
    }

    @Test
    fun cancellingBeforeTheTurnStillTurnsExactlyOnceAndNeverPresents() = runBlocking {
        val events = mutableListOf<String>()
        val gate = CompletableDeferred<String>()
        val runner = runner(events, capture = { events += "capture"; gate.await() })
        runner.turn(true, true, awaitTurn = { { events += "settled" } }, perform = { events += "perform" })
        runner.cancel()
        awaitEvent(events, "perform")
        delay(50)

        assertEquals(listOf("capture", "perform"), events)
    }

    @Test
    fun cancellingMidAnimationReleasesTheSnapshotOnce() = runBlocking {
        val events = mutableListOf<String>()
        val runner = runner(events, animate = { events += "animate"; awaitCancellation() })
        runner.turn(true, true, awaitTurn = { { } }, perform = { events += "perform" })
        awaitEvent(events, "animate")
        runner.cancel()
        awaitEvent(events, "release:snapshot")
        delay(50)

        assertEquals(1, events.count { it == "perform" })
        assertEquals(1, events.count { it == "release:snapshot" })
    }

    @Test
    fun aTurnDuringACurlInterruptsItAndTurnsDirectly() = runBlocking {
        val events = mutableListOf<String>()
        val runner = runner(events, animate = { events += "animate"; awaitCancellation() })
        runner.turn(true, true, awaitTurn = { { } }, perform = { events += "first" })
        awaitEvent(events, "animate")
        runner.turn(true, true, awaitTurn = { { events += "unexpected" } }, perform = { events += "second" })
        awaitEvent(events, "release:snapshot")

        assertEquals(1, events.count { it == "capture" })
        assertEquals(listOf("first", "second"), events.filter { it == "first" || it == "second" })
        assertFalse("unexpected" in events)
        assertFalse(runner.active)
    }

    @Test
    fun rapidTurnsReleaseEverySnapshotOnceAndKeepTurnOrder() = runBlocking {
        val events = mutableListOf<String>()
        var captures = 0
        val runner = runner(
            events,
            capture = { events += "capture"; "snapshot${++captures}" },
            animate = { events += "animate"; awaitCancellation() },
        )
        runner.turn(true, true, awaitTurn = { { } }, perform = { events += "first" })
        awaitEvent(events, "animate")
        runner.turn(true, true, awaitTurn = { { } }, perform = { events += "second" })
        runner.turn(true, true, awaitTurn = { { } }, perform = { events += "third" })
        withTimeout(2_000) { while (events.count { it == "animate" } < 2) yield() }
        runner.cancel()
        awaitEvent(events, "release:snapshot2")
        delay(50)

        assertEquals(listOf("first", "second", "third"), events.filter { it in setOf("first", "second", "third") })
        assertEquals(1, events.count { it == "release:snapshot1" })
        assertEquals(1, events.count { it == "release:snapshot2" })
        assertFalse(runner.active)
    }

    @Test
    fun closingDropsPendingTurnsAndIgnoresLaterCommands() = runBlocking {
        val events = mutableListOf<String>()
        val gate = CompletableDeferred<String>()
        val runner = runner(events, capture = { events += "capture"; gate.await() })
        runner.turn(true, true, awaitTurn = { { } }, perform = { events += "perform" })
        runner.close()
        delay(50)
        runner.turn(true, curl = false, awaitTurn = { { } }, perform = { events += "after close" })

        assertEquals(listOf("capture"), events)
    }

    private fun CoroutineScope.runner(
        events: MutableList<String>,
        capture: suspend () -> String? = { events += "capture"; "snapshot" },
        animate: suspend () -> Unit = { events += "animate" },
    ) = ReaderPageCurlRunner(
        scope = this,
        capture = capture,
        present = { snapshot, forward -> events += "present:$snapshot:$forward" },
        animate = animate,
        dismiss = { events += "release:$it" },
        settleTimeoutMs = 100,
    )

    private suspend fun awaitEvent(events: List<String>, event: String) {
        withTimeout(2_000) { while (event !in events) yield() }
    }
}
