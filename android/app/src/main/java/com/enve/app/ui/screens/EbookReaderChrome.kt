package com.enve.app.ui.screens

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.data.reader.ReaderProgressDisplay
import com.enve.app.viewmodel.ProgressConflictPrompt
import com.enve.core.data.sync.ProgressConflictPassage
import java.util.Locale

@Composable
internal fun ProgressConflictDialog(
    prompt: ProgressConflictPrompt,
    onChooseLocal: () -> Unit,
    onChooseRemote: () -> Unit,
    onDecideLater: () -> Unit,
) {
    val localPct = (prompt.localPercentage * 100).toInt().coerceIn(0, 100)
    val remotePct = (prompt.remotePercentage * 100).toInt().coerceIn(0, 100)
    AlertDialog(
        onDismissRequest = onDecideLater,
        title = { Text("Where do you want to continue?") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(
                    text = "This device and ${prompt.remoteSource} disagree. Pick which one to use, or dismiss to decide later.",
                    fontSize = 14.sp,
                )
                ProgressConflictOption(
                    title = "This device",
                    percent = localPct,
                    savedAgo = formatRelativeTime(prompt.localUpdatedAt),
                    passage = prompt.localPassage,
                )
                ProgressConflictOption(
                    title = prompt.remoteSource,
                    percent = remotePct,
                    savedAgo = formatRelativeTime(prompt.remoteUpdatedAt),
                    passage = prompt.remotePassage,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onChooseRemote) {
                Text("Use ${prompt.remoteSource} ($remotePct%)")
            }
        },
        dismissButton = {
            TextButton(onClick = onChooseLocal) {
                Text("Use this device ($localPct%)")
            }
        },
    )
}

@Composable
private fun ProgressConflictOption(
    title: String,
    percent: Int,
    savedAgo: String?,
    passage: ProgressConflictPassage?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            text = if (savedAgo != null) "$title — $percent% (saved $savedAgo)" else "$title — $percent%",
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
        )
        if (passage != null && passage.text.isNotBlank()) {
            passage.sectionTitle?.takeIf { it.isNotBlank() }?.let { section ->
                Text(
                    text = section,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Text(
                text = passage.text,
                fontSize = 13.sp,
                fontStyle = FontStyle.Italic,
                maxLines = 4,
                overflow = TextOverflow.Ellipsis,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 10.dp),
            )
            Text(
                text = passage.accuracy.label,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            Text(
                text = "Preview unavailable — showing progress only",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private fun formatRelativeTime(epochMs: Long?): String? {
    if (epochMs == null || epochMs <= 0L) return null
    val deltaSec = (System.currentTimeMillis() - epochMs) / 1000L
    return when {
        deltaSec < 0L -> null
        deltaSec < 60L -> "just now"
        deltaSec < 3600L -> "${deltaSec / 60} min ago"
        deltaSec < 86_400L -> "${deltaSec / 3600} h ago"
        else -> "${deltaSec / 86_400L} d ago"
    }
}

@Composable
internal fun ReaderStatusStrip(
    showClock: Boolean,
    showBattery: Boolean,
    progressDisplay: ReaderProgressDisplay,
    currentPage: Int,
    totalPages: Int,
    hasPageList: Boolean,
    currentPageLabel: String?,
    lastPageLabel: String?,
    progressPct: Int,
    chapter: String,
    chromeVisible: Boolean,
    textColor: Color,
    modifier: Modifier = Modifier,
) {
    if (chromeVisible) return

    val context = LocalContext.current

    val timeText = if (showClock) {
        val now by produceState(initialValue = System.currentTimeMillis()) {
            while (true) {
                value = System.currentTimeMillis()
                kotlinx.coroutines.delay(30_000)
            }
        }
        val fmt = remember { java.text.SimpleDateFormat("h:mm a", Locale.getDefault()) }
        fmt.format(java.util.Date(now))
    } else null

    val batteryPct = if (showBattery) {
        val pct by produceState(initialValue = readBatteryPercent(context)) {
            while (true) {
                value = readBatteryPercent(context)
                kotlinx.coroutines.delay(60_000)
            }
        }
        pct
    } else null

    val progressText = when (progressDisplay) {
        ReaderProgressDisplay.NONE -> null
        ReaderProgressDisplay.PAGE ->
            readerPositionText(
                currentPage,
                totalPages,
                hasPageList,
                currentPageLabel,
                lastPageLabel,
            ).takeIf { it.isNotEmpty() }
        ReaderProgressDisplay.PERCENT -> "$progressPct%"
        ReaderProgressDisplay.CHAPTER -> chapter.takeIf { it.isNotBlank() }
        ReaderProgressDisplay.PAGE_AND_PERCENT ->
            readerPositionText(
                currentPage,
                totalPages,
                hasPageList,
                currentPageLabel,
                lastPageLabel,
            )
                .takeIf { it.isNotEmpty() }
                ?.let { "$it · $progressPct%" }
                ?: "$progressPct%"
    }

    if (timeText == null && batteryPct == null && progressText == null) return

    Row(
        modifier = modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 14.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = listOfNotNull(timeText).joinToString("  "),
            color = textColor,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
        )
        Spacer(Modifier.weight(1f))
        progressText?.let {
            Text(
                text = it,
                color = textColor,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (batteryPct != null) {
            if (progressText != null) Spacer(Modifier.width(10.dp))
            Text(
                text = "$batteryPct%",
                color = textColor,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
            )
        }
    }
}

private fun readBatteryPercent(context: Context): Int {
    val mgr = context.getSystemService(Context.BATTERY_SERVICE) as? android.os.BatteryManager
    return mgr?.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: 0
}
