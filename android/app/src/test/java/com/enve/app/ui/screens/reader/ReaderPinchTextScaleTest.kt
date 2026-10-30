package com.enve.app.ui.screens.reader

import com.enve.app.data.reader.MAX_READER_FONT_SCALE
import com.enve.app.data.reader.MIN_READER_FONT_SCALE
import com.enve.app.data.reader.READER_FONT_SCALE_STEP
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderPinchTextScaleTest {
    @Test
    fun snappingLandsOnTheStepperGrid() {
        assertEquals(MIN_READER_FONT_SCALE, ReaderPinchTextScale.snap(0.1f), 1e-6f)
        assertEquals(MAX_READER_FONT_SCALE, ReaderPinchTextScale.snap(9f), 1e-6f)
        assertEquals(1.2f, ReaderPinchTextScale.snap(1.16f), 1e-6f)
        assertEquals(1.1f, ReaderPinchTextScale.snap(1.14f), 1e-6f)
        var scale = MIN_READER_FONT_SCALE
        while (scale <= MAX_READER_FONT_SCALE + 1e-4f) {
            val snapped = ReaderPinchTextScale.snap(scale)
            val steps = (snapped - MIN_READER_FONT_SCALE) / READER_FONT_SCALE_STEP
            assertEquals(steps.toString(), Math.round(steps).toFloat(), steps, 1e-3f)
            scale += 0.037f
        }
    }

    @Test
    fun restingTwoFingersHasNotMovedThem() {
        assertFalse(ReaderPinchTextScale.moved(startSpan = 300f, currentSpan = 300f))
        assertFalse(ReaderPinchTextScale.moved(startSpan = 300f, currentSpan = 318f))
        assertFalse(ReaderPinchTextScale.moved(startSpan = 4f, currentSpan = 400f))
        assertFalse(ReaderPinchTextScale.moved(startSpan = 300f, currentSpan = 0f))
        assertTrue(ReaderPinchTextScale.moved(startSpan = 300f, currentSpan = 400f))
        assertTrue(ReaderPinchTextScale.moved(startSpan = 400f, currentSpan = 300f))
    }

    @Test
    fun spreadingGrowsAndPinchingShrinksTheText() {
        val bigger = ReaderPinchTextScale.targetFor(startScale = 1f, startSpan = 200f, currentSpan = 300f)
        assertTrue(bigger != null && bigger > 1f)
        val smaller = ReaderPinchTextScale.targetFor(startScale = 1f, startSpan = 300f, currentSpan = 200f)
        assertTrue(smaller != null && smaller < 1f)
        assertEquals(1.5f, checkNotNull(bigger), 1e-6f)
        assertEquals(0.7f, checkNotNull(smaller), 1e-6f)
    }

    @Test
    fun comingBackToTheStartingSpanAsksForNothing() {
        assertNull(ReaderPinchTextScale.targetFor(startScale = 1.2f, startSpan = 200f, currentSpan = 200f))
        assertNull(ReaderPinchTextScale.targetFor(startScale = 1.2f, startSpan = 200f, currentSpan = 210f))
        assertNull(ReaderPinchTextScale.targetFor(startScale = 1.2f, startSpan = 4f, currentSpan = 400f))
    }

    @Test
    fun aMoveThatSnapsBackOntoTheCurrentSizeAsksForNothing() {
        assertNull(ReaderPinchTextScale.targetFor(startScale = MIN_READER_FONT_SCALE, startSpan = 300f, currentSpan = 270f))
        assertNull(ReaderPinchTextScale.targetFor(startScale = MAX_READER_FONT_SCALE, startSpan = 200f, currentSpan = 260f))
    }

    @Test
    fun theTargetNeverLeavesTheStepperRange() {
        assertEquals(MAX_READER_FONT_SCALE, checkNotNull(ReaderPinchTextScale.targetFor(2f, 100f, 4000f)), 1e-6f)
        assertEquals(MIN_READER_FONT_SCALE, checkNotNull(ReaderPinchTextScale.targetFor(0.8f, 4000f, 100f)), 1e-6f)
    }

    @Test
    fun theRatioAppliesToTheSizeTheGestureStartedFrom() {
        val start = 1.6f
        assertEquals(MAX_READER_FONT_SCALE, checkNotNull(ReaderPinchTextScale.targetFor(start, 200f, 900f)), 1e-6f)
        assertEquals(0.8f, checkNotNull(ReaderPinchTextScale.targetFor(start, 200f, 100f)), 1e-6f)
    }

    @Test
    fun theSpanIsTheDistanceBetweenTheFingers() {
        assertEquals(5f, ReaderPinchTextScale.spanOf(0f, 0f, 3f, 4f), 1e-4f)
        assertEquals(0f, ReaderPinchTextScale.spanOf(7f, 9f, 7f, 9f), 1e-4f)
    }
}
