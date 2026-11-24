package com.enve.app.cloud

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.ui.screens.reader.ReaderPageCurlDrawable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReaderPageCurlRenderingTest {
    @Test fun preservesTextDirectionAndClipsToPageViewport() {
        val page = Bitmap.createBitmap(200, 300, Bitmap.Config.ARGB_8888)
        Canvas(page).apply {
            drawColor(Color.RED)
            drawRect(100f, 0f, 200f, 300f, Paint().apply { color = Color.BLUE })
        }
        val result = Bitmap.createBitmap(240, 360, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(result)
        val drawable = ReaderPageCurlDrawable(1f).apply { setBounds(20, 30, 220, 330) }
        for (forward in listOf(true, false)) {
            result.eraseColor(Color.GREEN)
            drawable.show(page, forward)
            drawable.draw(canvas)
            assertEquals(Color.RED, result.getPixel(70, 180))
            assertEquals(Color.BLUE, result.getPixel(170, 180))
            assertEquals(Color.GREEN, result.getPixel(10, 180))
            drawable.progress = 0.5f
            result.eraseColor(Color.GREEN)
            drawable.draw(canvas)
            assertEquals(Color.GREEN, result.getPixel(10, 180))
            assertEquals(Color.GREEN, result.getPixel(120, 10))
            val pixels = IntArray(240 * 360)
            result.getPixels(pixels, 0, 240, 0, 0, 240, 360)
            assertTrue(pixels.any { it != Color.GREEN })
            drawable.clear(page)
        }
        page.recycle()
        result.recycle()
    }
}
