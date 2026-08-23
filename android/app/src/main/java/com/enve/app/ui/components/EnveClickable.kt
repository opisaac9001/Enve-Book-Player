package com.enve.app.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput

fun Modifier.enveClickable(
    enabled: Boolean = true,
    onClick: () -> Unit,
): Modifier = composed {
    var targetScale by remember { mutableFloatStateOf(1f) }
    val scale by animateFloatAsState(
        targetValue = targetScale,
        animationSpec = spring(dampingRatio = 0.75f, stiffness = 400f),
        label = "press_scale",
    )

    this
        .graphicsLayer {
            scaleX = scale
            scaleY = scale
        }
        .pointerInput(enabled) {
            awaitPointerEventScope {
                while (enabled) {
                    awaitFirstDown()
                    targetScale = 0.97f
                    val up = waitForUpOrCancellation()
                    targetScale = 1f
                    if (up != null) {
                        onClick()
                    }
                }
            }
        }
}
