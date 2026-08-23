package com.enve.app.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled

@Composable
fun EnveEmptyState(
    icon: ImageVector,
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    iconBackground: Color = EnveTheme.colors.accent.copy(alpha = 0.12f),
    iconTint: Color = EnveTheme.colors.accent,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    val scale = if (EnveTheme.isEink) {
        1f
    } else {
        val transition = rememberInfiniteTransition(label = "empty_state_pulse")
        val animated by transition.animateFloat(
            initialValue = 1f,
            targetValue = 1.04f,
            animationSpec = infiniteRepeatable(
                animation = tween(2000, easing = EaseInOutSine),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "pulse",
        )
        animated
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.XL.scaled(metrics), vertical = DS.Spacing.XXL.scaled(metrics)),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {
        Box(
            modifier = Modifier
                .size(80.dp.scaled(metrics))
                .scale(scale)
                .clip(CircleShape)
                .background(iconBackground),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = iconTint,
                modifier = Modifier.size(36.dp.scaled(metrics)),
            )
        }

        Text(
            text = title,
            color = colors.primaryText,
            fontSize = DS.FontSize.Title3.scaled(metrics),
            fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
            textAlign = TextAlign.Center,
        )

        Text(
            text = message,
            color = colors.secondaryText,
            fontSize = DS.FontSize.Body.scaled(metrics),
            textAlign = TextAlign.Center,
        )

        if (actionLabel != null && onAction != null) {
            Spacer(Modifier.height(DS.Spacing.SM.scaled(metrics)))
            Button(
                onClick = onAction,
                colors = ButtonDefaults.buttonColors(
                    containerColor = colors.accent.copy(alpha = 0.15f),
                    contentColor = colors.accent,
                ),
                shape = RoundedCornerShape(DS.Radius.Pill),
            ) {
                Text(
                    text = actionLabel,
                    fontSize = DS.FontSize.Subheadline.scaled(metrics),
                    fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
fun EmptyDownloadsState(
    modifier: Modifier = Modifier,
    onBrowse: (() -> Unit)? = null,
) {
    EnveEmptyState(
        icon = Icons.Default.Download,
        title = "No Offline Items",
        message = "Download audiobooks and ebooks to enjoy them without an internet connection.",
        actionLabel = "Browse Library",
        onAction = onBrowse,
        modifier = modifier,
    )
}
