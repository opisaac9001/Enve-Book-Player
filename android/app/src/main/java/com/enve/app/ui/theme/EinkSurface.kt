package com.enve.app.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

fun Modifier.einkShadow(
    elevation: Dp,
    shape: Shape,
    borderColor: Color = Color.Unspecified,
    clip: Boolean = false,
): Modifier = composed {
    val eink = LocalEinkProfile.current
    if (eink.borderInsteadOfShadow) {
        val resolved = if (borderColor == Color.Unspecified) {
            LocalEnveColors.current.separator
        } else borderColor
        this.border(1.dp, resolved, shape)
    } else {
        this.shadow(elevation, shape, clip = clip)
    }
}

fun Modifier.einkAwareBackground(
    brush: Brush,
    einkFill: Color,
    einkBorder: Color? = null,
    shape: Shape = RectangleShape,
): Modifier = composed {
    val eink = LocalEinkProfile.current
    if (eink.suppressGradients) {
        val withFill = this.background(einkFill, shape)
        if (einkBorder != null) withFill.border(1.dp, einkBorder, shape) else withFill
    } else {
        this.background(brush, shape)
    }
}
