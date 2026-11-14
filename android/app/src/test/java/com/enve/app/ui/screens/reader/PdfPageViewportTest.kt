package com.enve.app.ui.screens.reader

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.center
import com.enve.core.reader.PdfPageAdjust
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PdfPageViewportTest {
    private val portraitPage = Size(1000f, 1400f)
    private val spread = Size(2000f, 1400f)
    private val portraitView = Size(400f, 800f)
    private val landscapeView = Size(800f, 400f)
    private val far = 100_000f

    private fun assertSize(expectedWidth: Float, expectedHeight: Float, actual: Size) {
        assertEquals(expectedWidth, actual.width, 0.1f)
        assertEquals(expectedHeight, actual.height, 0.1f)
    }

    @Test
    fun eachSizingModeScalesThePageKeepingItsShape() {
        assertSize(400f, 560f, PdfPageZoom.baseSize(portraitPage, portraitView, PdfPageAdjust.FIT))
        assertSize(571.4f, 800f, PdfPageZoom.baseSize(portraitPage, portraitView, PdfPageAdjust.CROP))
        assertSize(571.4f, 800f, PdfPageZoom.baseSize(portraitPage, portraitView, PdfPageAdjust.FILL_HEIGHT))
        assertSize(400f, 560f, PdfPageZoom.baseSize(portraitPage, portraitView, PdfPageAdjust.FILL_WIDTH))

        assertSize(285.7f, 400f, PdfPageZoom.baseSize(portraitPage, landscapeView, PdfPageAdjust.FIT))
        assertSize(800f, 1120f, PdfPageZoom.baseSize(portraitPage, landscapeView, PdfPageAdjust.CROP))
        assertSize(285.7f, 400f, PdfPageZoom.baseSize(portraitPage, landscapeView, PdfPageAdjust.FILL_HEIGHT))
        assertSize(800f, 1120f, PdfPageZoom.baseSize(portraitPage, landscapeView, PdfPageAdjust.FILL_WIDTH))

        assertEquals(Size.Zero, PdfPageZoom.baseSize(portraitPage, Size.Zero, PdfPageAdjust.FIT))
    }

    @Test
    fun aFittedPageIsCenteredAndCannotPan() {
        val base = PdfPageZoom.baseSize(portraitPage, portraitView, PdfPageAdjust.FIT)
        val start = PdfPageTransform()
        assertFalse(PdfPageZoom.overflows(start, portraitView, base))
        val panned = PdfPageZoom.zoomed(start, portraitView.center, Offset(far, -far), 1f, portraitView, base)
        assertEquals(start, panned)
        val target = PdfPageZoom.destination(panned, portraitView, base)
        assertEquals(0f, target.left, 0.1f)
        assertEquals(120f, target.top, 0.1f)
        assertEquals(680f, target.bottom, 0.1f)
    }

    @Test
    fun everyInitiallyCroppedEdgeIsReachable() {
        val base = PdfPageZoom.baseSize(portraitPage, landscapeView, PdfPageAdjust.CROP)
        val start = PdfPageTransform()
        assertTrue(PdfPageZoom.overflows(start, landscapeView, base))

        val top = PdfPageZoom.zoomed(start, landscapeView.center, Offset(0f, far), 1f, landscapeView, base)
        assertEquals(0f, PdfPageZoom.destination(top, landscapeView, base).top, 0.1f)

        val bottom = PdfPageZoom.zoomed(start, landscapeView.center, Offset(0f, -far), 1f, landscapeView, base)
        assertEquals(landscapeView.height, PdfPageZoom.destination(bottom, landscapeView, base).bottom, 0.1f)

        val sideways = PdfPageZoom.zoomed(start, landscapeView.center, Offset(far, 0f), 1f, landscapeView, base)
        assertEquals(0f, sideways.offset.x, 0f)
    }

    @Test
    fun aZoomedSpreadPansExactlyToEachEdge() {
        val base = PdfPageZoom.baseSize(spread, portraitView, PdfPageAdjust.FIT)
        val zoomed = PdfPageZoom.zoomed(PdfPageTransform(), portraitView.center, Offset.Zero, 6f, portraitView, base)
        assertEquals(PdfPageZoom.MAX_SCALE, zoomed.scale, 0f)

        fun edge(pan: Offset) = PdfPageZoom.destination(
            PdfPageZoom.zoomed(zoomed, portraitView.center, pan, 1f, portraitView, base),
            portraitView,
            base,
        )
        assertEquals(0f, edge(Offset(far, 0f)).left, 0.1f)
        assertEquals(portraitView.width, edge(Offset(-far, 0f)).right, 0.1f)
        assertEquals(0f, edge(Offset(0f, far)).top, 0.1f)
        assertEquals(portraitView.height, edge(Offset(0f, -far)).bottom, 0.1f)
    }

    @Test
    fun pinchKeepsThePointUnderTheFingersInPlace() {
        val base = PdfPageZoom.baseSize(portraitPage, portraitView, PdfPageAdjust.FIT)
        val centroid = Offset(300f, 400f)
        val start = PdfPageTransform()
        val before = PdfPageZoom.destination(start, portraitView, base)
        val after = PdfPageZoom.destination(
            PdfPageZoom.zoomed(start, centroid, Offset.Zero, 2f, portraitView, base),
            portraitView,
            base,
        )
        val fractionX = (centroid.x - before.left) / before.width
        val fractionY = (centroid.y - before.top) / before.height
        assertEquals(centroid.x, after.left + fractionX * after.width, 0.1f)
        assertEquals(centroid.y, after.top + fractionY * after.height, 0.1f)
    }

    @Test
    fun scaleStaysBetweenTheSizingModeAndTheMaximum() {
        val base = PdfPageZoom.baseSize(portraitPage, portraitView, PdfPageAdjust.FILL_HEIGHT)
        val center = portraitView.center
        assertEquals(PdfPageZoom.MIN_SCALE, PdfPageZoom.zoomed(PdfPageTransform(), center, Offset.Zero, 0.1f, portraitView, base).scale, 0f)
        assertEquals(PdfPageZoom.MAX_SCALE, PdfPageZoom.zoomed(PdfPageTransform(), center, Offset.Zero, 100f, portraitView, base).scale, 0f)
    }

    @Test
    fun doubleTapZoomsInThenResets() {
        val base = PdfPageZoom.baseSize(portraitPage, portraitView, PdfPageAdjust.FIT)
        val zoomed = PdfPageZoom.toggled(PdfPageTransform(), Offset(100f, 200f), portraitView, base)
        assertEquals(PdfPageZoom.DOUBLE_TAP_SCALE, zoomed.scale, 1e-3f)
        assertFalse(PdfPageZoom.atBase(zoomed))
        assertEquals(PdfPageTransform(), PdfPageZoom.toggled(zoomed, Offset(100f, 200f), portraitView, base))
    }
}
