package com.enve.app.ui.screens.reader

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.reader.PdfPageAdjust
import com.enve.core.reader.PdfSpread
import com.enve.engine.eink.EinkState
import com.enve.hearth.design.HearthEink
import com.enve.hearth.design.HearthTheme
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PdfPageViewportVerificationTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun pinchZoomRespondsToTwoFingers() {
        show(eink = false)
        page().performTouchInput {
            down(0, center - Offset(40f, 0f))
            down(1, center + Offset(40f, 0f))
            moveTo(0, center - Offset(140f, 0f), delayMillis = 100)
            moveTo(1, center + Offset(140f, 0f), delayMillis = 100)
            up(0)
            up(1)
        }
        assertTrue(page().fetchSemanticsNode().config[SemanticsActions.CustomActions].any { it.label == "Reset zoom" })
    }

    @Test
    fun einkPanDrawsThePreviouslyClippedEdgeOnlyAfterRelease() {
        show(eink = true)
        assertFalse(leftMarkerVisible())
        page().performTouchInput {
            down(Offset(width * 0.1f, height / 2f))
            moveTo(Offset(width * 0.9f, height / 2f), delayMillis = 200)
        }
        assertFalse(leftMarkerVisible())
        page().performTouchInput { up() }
        assertTrue(leftMarkerVisible())
    }

    private fun show(eink: Boolean) {
        val bitmap = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).apply {
            drawColor(Color.WHITE)
            drawRect(20f, 120f, 50f, 280f, Paint().apply { color = Color.RED })
        }
        compose.setContent {
            HearthTheme(eink = HearthEink(EinkState.Inactive.copy(active = eink))) {
                PdfPageViewport(
                    bitmap, PdfSpread(0, 0), PdfPageAdjust.FILL_HEIGHT, "PDF viewport",
                    Modifier.size(300.dp, 400.dp),
                )
            }
        }
    }

    private fun page() = compose.onNodeWithContentDescription("PDF viewport")

    private fun leftMarkerVisible(): Boolean {
        val pixels = page().captureToImage().toPixelMap()
        for (y in 0 until pixels.height) {
            for (x in 0 until pixels.width) {
                val color = pixels[x, y]
                if (color.red > 0.8f && color.green < 0.2f && color.blue < 0.2f) return true
            }
        }
        return false
    }
}
