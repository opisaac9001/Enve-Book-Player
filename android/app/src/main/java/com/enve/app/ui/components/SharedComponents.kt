package com.enve.app.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveColors
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink

@Composable
fun DynamicEnveBackground(
    modifier: Modifier = Modifier,
    animated: Boolean = false,
    fullScreen: Boolean = false,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    if (EnveTheme.eink.suppressGradients) {

        Box(
            modifier = if (fullScreen) modifier.fillMaxSize() else modifier
                .fillMaxWidth()
                .height(160.dp.scaled(metrics))
        ) {
            Canvas(modifier = Modifier.matchParentSize()) {
                drawRect(color = colors.background)
            }
        }
        return
    }

    val transition = rememberInfiniteTransition(label = "enve_background")
    val driftOne by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = if (animated) 18000 else 1, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "background_drift_one",
    )
    val driftTwo by transition.animateFloat(
        initialValue = 1f,
        targetValue = 0f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = if (animated) 24000 else 1, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "background_drift_two",
    )
    val driftThree by transition.animateFloat(
        initialValue = 0.35f,
        targetValue = 0.95f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = if (animated) 30000 else 1, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "background_drift_three",
    )

    val accentPurple = lerp(colors.accent, EnveColors.Primary, 0.58f)
    val accentBlue = lerp(colors.accent, EnveColors.FixedAccent, 0.72f)
    val accentWarm = lerp(colors.accent, Color(0xFFFF8A65), 0.42f)

    Canvas(
        modifier = if (fullScreen) {
            modifier.fillMaxSize()
        } else {
            modifier
                .fillMaxWidth()
                .height(if (animated) 560.dp.scaled(metrics) else 260.dp.scaled(metrics))
        }
    ) {
        drawRect(
            brush = Brush.linearGradient(
                colors = listOf(
                    colors.background,
                    lerp(colors.background, colors.cardBackground, 0.18f),
                    colors.background,
                ),
                start = Offset.Zero,
                end = Offset(size.width, size.height),
            )
        )

        if (animated) {
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(
                        accentPurple.copy(alpha = 0.16f),
                        accentBlue.copy(alpha = 0.08f),
                        Color.Transparent,
                    ),
                    center = Offset(size.width * (0.78f - 0.16f * driftOne), size.height * (0.18f + 0.06f * driftTwo)),
                    radius = size.width * 0.72f,
                ),
                radius = size.width * 0.72f,
                center = Offset(size.width * (0.78f - 0.16f * driftOne), size.height * (0.18f + 0.06f * driftTwo)),
            )

            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(
                        accentBlue.copy(alpha = 0.12f),
                        accentPurple.copy(alpha = 0.06f),
                        Color.Transparent,
                    ),
                    center = Offset(size.width * (0.18f + 0.10f * driftTwo), size.height * (0.34f - 0.08f * driftThree)),
                    radius = size.width * 0.62f,
                ),
                radius = size.width * 0.62f,
                center = Offset(size.width * (0.18f + 0.10f * driftTwo), size.height * (0.34f - 0.08f * driftThree)),
            )

            drawOval(
                brush = Brush.radialGradient(
                    colors = listOf(
                        accentWarm.copy(alpha = 0.10f),
                        accentPurple.copy(alpha = 0.05f),
                        Color.Transparent,
                    ),
                    center = Offset(size.width * (0.52f + 0.06f * driftThree), size.height * (0.10f + 0.04f * driftOne)),
                    radius = size.width * 0.58f,
                ),
                topLeft = Offset(size.width * 0.08f, -size.height * 0.12f),
                size = Size(size.width * 0.84f, size.height * 0.46f),
            )
        } else {
            drawRect(
                brush = Brush.linearGradient(
                    colors = listOf(
                        accentPurple.copy(alpha = 0.18f),
                        accentBlue.copy(alpha = 0.10f),
                        Color.Transparent,
                    ),
                    start = Offset(0f, 0f),
                    end = Offset(size.width, size.height * 0.9f),
                )
            )
        }

        drawRect(
            brush = Brush.verticalGradient(
                colors = listOf(
                    colors.background.copy(alpha = 0f),
                    colors.background.copy(alpha = 0.12f),
                    colors.background.copy(alpha = 0.52f),
                    colors.background,
                ),
                startY = size.height * 0.08f,
                endY = size.height,
            )
        )

        drawRect(
            brush = Brush.verticalGradient(
                colors = listOf(
                    accentPurple.copy(alpha = if (animated) 0.08f else 0.12f),
                    Color.Transparent,
                ),
                startY = 0f,
                endY = size.height * 0.42f,
            )
        )
    }
}

@Composable
fun MediaTypePills(
    selectedType: com.enve.core.data.model.AppMediaType,
    onTypeSelected: (com.enve.core.data.model.AppMediaType) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val types = listOf(
        Triple(com.enve.core.data.model.AppMediaType.AUDIOBOOK, "Audio", Icons.Default.Headphones),
        Triple(com.enve.core.data.model.AppMediaType.EBOOK, "Books", Icons.Default.Book),
    )

    Row(
        modifier = modifier
            .clip(RoundedCornerShape(DS.Radius.Pill))
            .background(colors.secondaryBackground.copy(alpha = 0.9f))
            .padding(3.dp.scaled(metrics)),
        horizontalArrangement = Arrangement.spacedBy(2.dp.scaled(metrics)),
    ) {
        types.forEach { (type, label, icon) ->
            val isSelected = type == selectedType
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(DS.Radius.Pill))
                    .background(if (isSelected) colors.cardBackground else Color.Transparent)
                    .clickable { onTypeSelected(type) }
                    .padding(horizontal = 10.dp.scaled(metrics), vertical = 6.dp.scaled(metrics)),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(DS.Spacing.XXS.scaled(metrics)),
                ) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = if (isSelected) colors.primaryText else colors.secondaryText,
                        modifier = Modifier.size(14.dp.scaled(metrics)),
                    )
                    Text(
                        text = label,
                        color = if (isSelected) colors.primaryText else colors.secondaryText,
                        fontSize = DS.FontSize.Caption2.scaled(metrics),
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }
    }
}
