package com.enve.hearth.design

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

@Composable
fun Ribbon(
    progress: Float,
    modifier: Modifier = Modifier,
    fill: Color = Hearth.palette.ember,
    ticks: List<Float> = emptyList(),
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val thickness = if (eink.active) 5.dp else 3.dp
    val clamped = progress.coerceIn(0f, 1f)

    Canvas(modifier.fillMaxWidth().height(thickness)) {
        val r = if (eink.sharpCorners) CornerRadius.Zero else CornerRadius(size.height / 2f)
        drawRoundRect(color = palette.hairline, cornerRadius = r)
        if (clamped > 0f) {
            drawRoundRect(
                color = fill,
                size = Size(size.width * clamped, size.height),
                cornerRadius = r,
            )
        }
        val tickColor = if (palette.isInk) Color.White.copy(alpha = 0.55f) else palette.bg
        ticks.forEach { t ->
            val x = size.width * t.coerceIn(0f, 1f)
            drawLine(
                color = tickColor,
                start = Offset(x, 0f),
                end = Offset(x, size.height),
                strokeWidth = 1.5f,
            )
        }
    }
}
