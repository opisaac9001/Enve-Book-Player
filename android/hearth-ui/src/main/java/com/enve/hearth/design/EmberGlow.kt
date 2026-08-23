package com.enve.hearth.design

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

@Composable
fun EmberGlow(
    color: Color,
    playing: Boolean,
    modifier: Modifier = Modifier,
) {
    if (Hearth.eink.suppressGradients || Hearth.reduceMotion) {
        Box(modifier)
        return
    }

    val transition = rememberInfiniteTransition(label = "emberGlow")
    val breath by transition.animateFloat(
        initialValue = 1f,
        targetValue = if (playing) 1.06f else 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(Hearth.Motion.GlowCycleMs),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "breath",
    )

    Box(
        modifier.fillMaxSize().drawBehind {
            val radius = maxOf(size.width, size.height) * 0.75f * breath
            drawRect(
                brush = Brush.radialGradient(
                    colors = listOf(color.copy(alpha = 0.30f), Color.Transparent),
                    center = Offset(size.width / 2f, size.height * 0.42f),
                    radius = radius,
                ),
            )
        },
    )
}
