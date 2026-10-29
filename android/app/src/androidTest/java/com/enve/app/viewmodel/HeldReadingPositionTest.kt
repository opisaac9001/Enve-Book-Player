package com.enve.app.viewmodel

import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.ReaderEngineKind
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.util.Url
import org.readium.r2.shared.util.mediatype.MediaType
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import androidx.test.ext.junit.runners.AndroidJUnit4

@RunWith(AndroidJUnit4::class)
class HeldReadingPositionTest {
    private fun locator(progress: Double, href: String = "chapter.xhtml") = Locator(
        href = Url(href)!!, mediaType = MediaType.XHTML,
        locations = Locator.Locations(totalProgression = progress),
    )

    private fun capture(progress: Double) = ReadiumCheckpointCapture(locator(progress), EpubBridgeCheckpoint(
        publicationSha256 = "fixture", writerEpoch = 1, revision = 0, observedAt = 1,
        sourceEngine = ReaderEngineKind.READIUM, href = "chapter.xhtml", totalProgression = progress,
    ))

    @Test fun invalidationRetainsTheLastCapturedPlace() {
        val state = HeldReadingPosition()
        val first = capture(0.3)
        assertTrue(state.hold(first, state.observe(first.locator)))
        state.invalidate()
        assertEquals(first, state.current())
    }

    @Test fun aNewLocationWinsBeforeItsMeasurementFinishes() {
        val state = HeldReadingPosition()
        val first = capture(0.3)
        state.hold(first, state.observe(first.locator))
        val next = locator(0.2)
        state.observe(next)
        assertNull(state.current())
        assertEquals(next, state.locator())
    }

    @Test fun lateAnswerCannotUndoABackwardJump() {
        val state = HeldReadingPosition()
        val old = state.observe(locator(0.5))
        state.invalidate()
        val current = capture(0.2)
        assertTrue(state.hold(current, state.observe(current.locator)))
        assertFalse(state.hold(capture(0.5), old))
        assertEquals(current, state.current())
    }

    @Test fun leavingChapterRetiresItsCapturedAnchor() {
        val state = HeldReadingPosition()
        val first = capture(0.3)
        state.hold(first, state.observe(first.locator))
        val next = locator(0.4, "next.xhtml")
        state.observe(next)
        assertNull(state.current())
        assertEquals(next, state.locator())
        state.retire()
        assertNull(state.locator())
    }

    @Test fun firstAnswerWinsWithinOneGeneration() {
        val state = HeldReadingPosition()
        val generation = state.observe(locator(0.4))
        assertTrue(state.hold(capture(0.4), generation))
        assertFalse(state.hold(capture(0.3), generation))
    }
}
