package com.enve.app.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import kotlin.math.min

data class StorageSegment(
    val label: String,
    val valueMb: Float,
    val color: Color,
)

@Composable
fun StorageDonutChart(
    segments: List<StorageSegment>,
    totalMb: Float,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val animatedProgress by animateFloatAsState(
        targetValue = 1f,
        animationSpec = tween(800, easing = FastOutSlowInEasing),
        label = "chart_progress",
    )

    Box(
        modifier = modifier
            .size(180.dp.scaled(metrics)),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokeWidth = 28f
            val diameter = min(size.width, size.height) - strokeWidth
            val topLeft = Offset(
                (size.width - diameter) / 2f,
                (size.height - diameter) / 2f,
            )
            val arcSize = Size(diameter, diameter)

            var startAngle = -90f

            segments.forEach { segment ->
                val sweep = (segment.valueMb / totalMb) * 360f * animatedProgress
                if (sweep > 0.5f) {
                    drawArc(
                        color = segment.color,
                        startAngle = startAngle,
                        sweepAngle = sweep,
                        useCenter = false,
                        topLeft = topLeft,
                        size = arcSize,
                        style = Stroke(width = strokeWidth, cap = StrokeCap.Round),
                    )
                }
                startAngle += sweep
            }

            drawArc(
                color = colors.separator.copy(alpha = 0.25f),
                startAngle = -90f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = topLeft,
                size = arcSize,
                style = Stroke(width = strokeWidth, cap = StrokeCap.Round),
            )
        }

        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = "%.1f".format(totalMb / 1024f),
                color = colors.primaryText,
                fontSize = DS.FontSize.Title2.scaled(metrics),
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = "GB total",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
        }
    }
}

@Composable
fun StorageLegend(
    segments: List<StorageSegment>,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
    ) {
        segments.forEach { segment ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
            ) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(androidx.compose.foundation.shape.CircleShape)
                        .background(segment.color),
                )
                Text(
                    text = segment.label,
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = "%.1f MB".format(segment.valueMb),
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}
