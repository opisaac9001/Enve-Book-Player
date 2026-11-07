package com.enve.hearth.shell

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FileDownload
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.engine.downloads.DownloadTransfer
import com.enve.engine.downloads.DownloadTransferStatus
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.hearthUI
import java.text.NumberFormat
import kotlin.math.roundToInt

internal data class DownloadPillSummary(
    val count: Int,
    val transferring: Boolean,
    val fraction: Float?,
) {
    val label: String
        get() = when {
            !transferring -> "$count queued"
            count == 1 -> "Downloading"
            else -> "Downloading $count"
        }

    val accessibilityValue: String
        get() {
            val items = if (count == 1) "1 item" else "$count items"
            return when {
                !transferring -> "$items queued"
                fraction == null -> "$items, starting"
                else -> "$items, ${(fraction * 100).roundToInt()} percent"
            }
        }
}

internal fun downloadPillSummary(transfers: List<DownloadTransfer>): DownloadPillSummary? {
    if (transfers.isEmpty()) return null
    val transferring = transfers.any { it.status == DownloadTransferStatus.DOWNLOADING }
    val started = transfers.any { it.progress > 0f || it.downloadedBytes > 0L }
    val fraction = when {
        transferring && !started -> null
        transfers.all { it.totalBytes > 0L } ->
            transfers.sumOf { it.downloadedBytes }.toFloat() / transfers.sumOf { it.totalBytes }
        else -> transfers.map { it.progress }.average().toFloat()
    }?.coerceIn(0f, 1f)
    return DownloadPillSummary(transfers.size, transferring, fraction)
}

@Composable
fun DownloadProgressPill(
    transfers: List<DownloadTransfer>,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val summary = downloadPillSummary(transfers)
    var lastSummary by remember { mutableStateOf(summary) }
    LaunchedEffect(summary) { if (summary != null) lastSummary = summary }
    val eink = Hearth.eink
    val reduceMotion = Hearth.reduceMotion
    val enter = when {
        eink.suppressAnimations -> EnterTransition.None
        reduceMotion -> fadeIn()
        else -> slideInVertically { it } + fadeIn()
    }
    val exit = when {
        eink.suppressAnimations -> ExitTransition.None
        reduceMotion -> fadeOut()
        else -> slideOutVertically { it } + fadeOut()
    }
    AnimatedVisibility(visible = summary != null, modifier = modifier, enter = enter, exit = exit) {
        (summary ?: lastSummary)?.let { PillContent(it, onOpen, animate = !eink.suppressAnimations && !reduceMotion) }
    }
}

@Composable
private fun PillContent(summary: DownloadPillSummary, onOpen: () -> Unit, animate: Boolean) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = if (eink.sharpCorners) RectangleShape else CircleShape
    val percent = summary.fraction?.takeIf { summary.transferring }?.let { NumberFormat.getPercentInstance().format((it * 100).roundToInt() / 100.0) }
    Row(
        Modifier
            .heightIn(min = 48.dp)
            .then(if (eink.suppressShadows) Modifier else Modifier.shadow(8.dp, shape, clip = false))
            .clip(shape)
            .background(palette.bgElevated)
            .border(if (eink.active) 1.5.dp else 1.dp, if (eink.active) palette.text else palette.hairline, shape)
            .clickable(onClick = onOpen)
            .testTag("download-progress-pill")
            .clearAndSetSemantics {
                role = Role.Button
                contentDescription = "Downloads"
                stateDescription = summary.accessibilityValue
                onClick(label = "Open Downloads") { onOpen(); true }
            }
            .padding(horizontal = 14.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TransferRing(summary, animate)
        Text(
            summary.label,
            style = hearthUI(13.sp, FontWeight.SemiBold),
            color = palette.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        if (percent != null) {
            Text(percent, style = HearthText.Caption.copy(fontFeatureSettings = "tnum"), color = palette.textSecondary, maxLines = 1)
        }
    }
}

@Composable
private fun TransferRing(summary: DownloadPillSummary, animate: Boolean) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val ringSize = with(LocalDensity.current) { 22.sp.toDp() }
    val progressColor = if (eink.monochrome) palette.text else palette.ember
    val fraction by animateFloatAsState(
        targetValue = summary.fraction ?: 0f,
        animationSpec = if (animate) tween(250, easing = LinearEasing) else snap(),
        label = "downloadFraction",
    )
    Box(Modifier.size(ringSize), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = 2.5.dp.toPx()
            val inset = stroke / 2f
            val arcSize = Size(size.width - stroke, size.height - stroke)
            val topLeft = Offset(inset, inset)
            if (!eink.monochrome) {
                drawArc(palette.hairline, -90f, 360f, false, topLeft, arcSize, style = Stroke(stroke))
            }
            if (summary.transferring && summary.fraction != null) {
                drawArc(progressColor, -90f, 360f * fraction, false, topLeft, arcSize, style = Stroke(stroke, cap = StrokeCap.Round))
            }
        }
        when {
            !summary.transferring -> Icon(
                Icons.Outlined.Schedule,
                contentDescription = null,
                tint = palette.textSecondary,
                modifier = Modifier.size(ringSize * 0.6f),
            )
            summary.fraction == null && animate -> CircularProgressIndicator(
                Modifier.fillMaxSize(),
                color = progressColor,
                strokeWidth = 2.5.dp,
            )
            summary.fraction == null -> Icon(
                Icons.Outlined.FileDownload,
                contentDescription = null,
                tint = progressColor,
                modifier = Modifier.size(ringSize * 0.6f),
            )
        }
    }
}
