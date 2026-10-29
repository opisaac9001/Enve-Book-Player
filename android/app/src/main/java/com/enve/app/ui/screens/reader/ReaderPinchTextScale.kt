package com.enve.app.ui.screens.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.unit.dp
import com.enve.app.data.reader.MAX_READER_FONT_SCALE
import com.enve.app.data.reader.MIN_READER_FONT_SCALE
import com.enve.app.data.reader.READER_FONT_SCALE_STEP
import com.enve.hearth.design.HearthPalette
import com.enve.hearth.design.HearthText
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.roundToInt

object ReaderPinchTextScale {
    const val DEAD_ZONE = 0.08f
    const val MIN_START_SPAN_PX = 24f

    private val steps = ((MAX_READER_FONT_SCALE - MIN_READER_FONT_SCALE) / READER_FONT_SCALE_STEP).roundToInt()

    fun snap(scale: Float): Float {
        val step = ((scale - MIN_READER_FONT_SCALE) / READER_FONT_SCALE_STEP).roundToInt().coerceIn(0, steps)
        val snapped = MIN_READER_FONT_SCALE + step * READER_FONT_SCALE_STEP
        return (snapped * 100f).roundToInt() / 100f
    }

    fun moved(startSpan: Float, currentSpan: Float): Boolean {
        if (startSpan < MIN_START_SPAN_PX || currentSpan <= 0f) return false
        return abs(currentSpan / startSpan - 1f) >= DEAD_ZONE
    }

    fun targetFor(startScale: Float, startSpan: Float, currentSpan: Float): Float? {
        if (!moved(startSpan, currentSpan)) return null
        return snap(startScale * (currentSpan / startSpan)).takeIf { it != snap(startScale) }
    }

    fun spanOf(x1: Float, y1: Float, x2: Float, y2: Float): Float = hypot(x2 - x1, y2 - y1)
}

@Composable
fun ReaderPinchTextScaleIndicator(scale: Float, palette: HearthPalette, eink: Boolean) {
    val shape = if (eink) RectangleShape else RoundedCornerShape(50)
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text = "Text size ${(scale * 100).roundToInt()}%",
            style = HearthText.Label,
            color = palette.text,
            modifier = Modifier
                .background(palette.bgElevated, shape)
                .border(1.dp, palette.hairline, shape)
                .padding(horizontal = 18.dp, vertical = 10.dp),
        )
    }
}
