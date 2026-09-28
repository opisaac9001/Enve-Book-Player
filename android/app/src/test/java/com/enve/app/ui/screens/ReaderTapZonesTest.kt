package com.enve.app.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test

class ReaderTapZonesTest {
    @Test
    fun edgesTurnPagesAndTheMiddleTogglesControls() {
        assertEquals(ReaderTapZone.LEFT_EDGE, ReaderTapZones.zoneAt(x = 150f, width = 1000f, edgeFraction = 0.2f))
        assertEquals(ReaderTapZone.CENTER, ReaderTapZones.zoneAt(x = 500f, width = 1000f, edgeFraction = 0.2f))
        assertEquals(ReaderTapZone.RIGHT_EDGE, ReaderTapZones.zoneAt(x = 850f, width = 1000f, edgeFraction = 0.2f))
    }

    @Test
    fun edgeWidthStaysWithinTheReaderLimits() {
        assertEquals(ReaderTapZone.LEFT_EDGE, ReaderTapZones.zoneAt(x = 140f, width = 1000f, edgeFraction = 0.05f))
        assertEquals(ReaderTapZone.CENTER, ReaderTapZones.zoneAt(x = 360f, width = 1000f, edgeFraction = 0.9f))
    }
}
