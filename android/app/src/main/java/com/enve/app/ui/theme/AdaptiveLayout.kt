package com.enve.app.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt

@Immutable
data class AdaptiveMetrics(
    val widthDp: Int,
    val heightDp: Int,
    val scaleFactor: Float,
) {
    val isCompactWidth: Boolean get() = widthDp < 380
    val isExpandedWidth: Boolean get() = widthDp >= 430
}

@Composable
fun rememberAdaptiveMetrics(): AdaptiveMetrics {
    val configuration = LocalConfiguration.current
    return remember(configuration.screenWidthDp, configuration.screenHeightDp) {
        val shortestSide = minOf(configuration.screenWidthDp, configuration.screenHeightDp).coerceAtLeast(320)
        val scaleFactor = (shortestSide / 390f).coerceIn(0.88f, 1.14f)
        AdaptiveMetrics(
            widthDp = configuration.screenWidthDp,
            heightDp = configuration.screenHeightDp,
            scaleFactor = scaleFactor,
        )
    }
}

@Stable
fun Dp.scaled(metrics: AdaptiveMetrics): Dp = (value * metrics.scaleFactor).dp

@Stable
fun TextUnit.scaled(metrics: AdaptiveMetrics): TextUnit = (value * metrics.scaleFactor).sp

@Stable
fun Int.scaled(metrics: AdaptiveMetrics): Int = (this * metrics.scaleFactor).roundToInt()