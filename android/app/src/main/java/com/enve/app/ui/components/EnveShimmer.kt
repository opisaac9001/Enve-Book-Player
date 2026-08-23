package com.enve.app.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.unit.dp
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled

@Composable
fun EnveShimmerBox(
    modifier: Modifier = Modifier,
    shape: RoundedCornerShape = RoundedCornerShape(DS.Radius.Card),
) {
    val colors = EnveTheme.colors

    if (EnveTheme.isEink) {

        Box(
            modifier = modifier
                .clip(shape)
                .background(colors.cardBackground),
        )
        return
    }

    val shimmerColors = listOf(
        colors.cardBackground.copy(alpha = 0.45f),
        colors.cardBackground.copy(alpha = 0.75f),
        colors.cardBackground.copy(alpha = 0.45f),
    )
    val transition = rememberInfiniteTransition(label = "shimmer")
    val translateAnim by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1000f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1200, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "shimmer_translate",
    )
    val brush = Brush.linearGradient(
        colors = shimmerColors,
        start = Offset.Zero,
        end = Offset(x = translateAnim, y = translateAnim),
    )
    Box(
        modifier = modifier
            .clip(shape)
            .background(brush),
    )
}

@Composable
fun BookRowSkeleton(
    modifier: Modifier = Modifier,
) {
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {
        EnveShimmerBox(
            modifier = Modifier
                .size(60.dp.scaled(metrics))
                .clip(RoundedCornerShape(DS.Radius.Small)),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.XS.scaled(metrics)),
        ) {
            EnveShimmerBox(
                modifier = Modifier
                    .fillMaxWidth(0.7f)
                    .height(14.dp),
                shape = RoundedCornerShape(4.dp),
            )
            EnveShimmerBox(
                modifier = Modifier
                    .fillMaxWidth(0.5f)
                    .height(12.dp),
                shape = RoundedCornerShape(4.dp),
            )
        }
    }
}

@Composable
fun HeroSkeleton(
    modifier: Modifier = Modifier,
) {
    val metrics = rememberAdaptiveMetrics()
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {
        EnveShimmerBox(
            modifier = Modifier
                .fillMaxWidth()
                .height(180.dp.scaled(metrics))
                .clip(RoundedCornerShape(DS.Radius.Large)),
        )
        EnveShimmerBox(
            modifier = Modifier
                .fillMaxWidth(0.5f)
                .height(20.dp),
            shape = RoundedCornerShape(4.dp),
        )
    }
}
