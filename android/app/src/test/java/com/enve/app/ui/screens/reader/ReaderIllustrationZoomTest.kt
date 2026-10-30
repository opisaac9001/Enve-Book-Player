package com.enve.app.ui.screens.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderIllustrationZoomTest {
    @Test
    fun aPictureIsFittedInsideTheViewportKeepingItsShape() {
        val wide = ReaderIllustrationZoom.fitted(2000f, 1000f, 1000f, 1000f)
        assertEquals(1000f, wide.width, 1e-3f)
        assertEquals(500f, wide.height, 1e-3f)
        val tall = ReaderIllustrationZoom.fitted(500f, 2000f, 1000f, 1000f)
        assertEquals(250f, tall.width, 1e-3f)
        assertEquals(1000f, tall.height, 1e-3f)
        assertEquals(0f, ReaderIllustrationZoom.fitted(0f, 10f, 100f, 100f).width, 0f)
    }

    @Test
    fun aFittedPictureCannotBePannedOffTheScreen() {
        assertEquals(0f, ReaderIllustrationZoom.clampPan(80f, 1000f, 1000f), 0f)
        assertEquals(0f, ReaderIllustrationZoom.clampPan(-80f, 1000f, 600f), 0f)
    }

    @Test
    fun aZoomedPictureCanPanOnlyAsFarAsItsOverflow() {
        assertEquals(250f, ReaderIllustrationZoom.clampPan(900f, 1000f, 1500f), 0f)
        assertEquals(-250f, ReaderIllustrationZoom.clampPan(-900f, 1000f, 1500f), 0f)
        assertEquals(100f, ReaderIllustrationZoom.clampPan(100f, 1000f, 1500f), 0f)
    }

    @Test
    fun scaleStaysBetweenFitAndTheMaximum() {
        assertEquals(ReaderIllustrationZoom.MIN_SCALE, ReaderIllustrationZoom.clampScale(0.2f), 0f)
        assertEquals(ReaderIllustrationZoom.MAX_SCALE, ReaderIllustrationZoom.clampScale(40f), 0f)
        assertTrue(ReaderIllustrationZoom.atFit(1.01f))
        assertFalse(ReaderIllustrationZoom.atFit(ReaderIllustrationZoom.DOUBLE_TAP_SCALE))
    }
}
