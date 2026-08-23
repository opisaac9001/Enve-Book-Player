@file:OptIn(ExperimentalLayoutApi::class)

package com.enve.hearth.player

import android.content.ActivityNotFoundException
import android.content.pm.ApplicationInfo
import android.content.Intent
import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.engine.sleep.SleepDataAccess
import com.enve.engine.sleep.SleepPeriod
import com.enve.engine.sleep.SleepStageKind
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.hearthDisplay
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlin.math.roundToInt

internal enum class SleepSheetTab { TIMER, INSIGHTS }

@Composable
internal fun SleepSheetTabs(tab: SleepSheetTab, onSelect: (SleepSheetTab) -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Inner)).background(palette.bgSunken)
            .padding(Hearth.Spacing.XS),
    ) {
        SleepTab("Timer", tab == SleepSheetTab.TIMER, Modifier.weight(1f)) { onSelect(SleepSheetTab.TIMER) }
        SleepTab("Sleep insights", tab == SleepSheetTab.INSIGHTS, Modifier.weight(1f)) { onSelect(SleepSheetTab.INSIGHTS) }
    }
}

@Composable
private fun SleepTab(label: String, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val palette = Hearth.palette
    Box(
        modifier.clip(RoundedCornerShape(Hearth.Radius.Inner))
            .background(if (selected) palette.emberSoft else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = HearthText.Label,
            color = if (selected) palette.ember else palette.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
internal fun SleepInsightsSheet(
    vm: HearthPlayerViewModel,
    modifier: Modifier = Modifier.fillMaxWidth().heightIn(max = 620.dp),
) {
    val context = LocalContext.current
    val state by vm.sleepTracker.collectAsStateWithLifecycle()
    val isDebuggable = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
    var selectedNightId by rememberSaveable { mutableStateOf<String?>(null) }
    val permission = HealthPermission.getReadPermission(SleepSessionRecord::class)
    val permissionLauncher = rememberLauncherForActivityResult(
        contract = PermissionController.createRequestPermissionResultContract(),
    ) { vm.refreshSleepTracker() }
    LaunchedEffect(Unit) { vm.refreshSleepTracker() }

    if (state.loading && state.summary == null) {
        Box(Modifier.fillMaxWidth().height(240.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = Hearth.palette.ember)
        }
        return
    }

    LazyColumn(
        modifier,
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
    ) {
        item {
            when (state.access) {
                SleepDataAccess.PERMISSION_REQUIRED -> AccessCard(
                    title = "Connect your sleep data",
                    body = "Enve reads sleep sessions from Health Connect to match your audiobook wind-down with when you fell asleep. Your health data stays on this device.",
                    action = "Allow sleep access",
                    onAction = { permissionLauncher.launch(setOf(permission)) },
                    secondaryAction = "Manage access",
                    onSecondaryAction = { openHealthConnectSettings(context) },
                )
                SleepDataAccess.PROVIDER_UPDATE_REQUIRED -> AccessCard(
                    title = "Health Connect needs an update",
                    body = "Install or update Health Connect to add recorded sleep stages and nightly trends.",
                    action = "Open Health Connect",
                    onAction = { openHealthConnectStore(context) },
                )
                SleepDataAccess.UNSUPPORTED -> AccessCard(
                    title = "Sleep data isn't available here",
                    body = "Health Connect requires Android 9 or newer with Google Play services. Enve can still show your bedtime listening habits below.",
                )
                SleepDataAccess.ERROR -> AccessCard(
                    title = "Sleep data couldn't load",
                    body = "Check Health Connect access, then try again.",
                    action = "Try again",
                    onAction = vm::refreshSleepTracker,
                    secondaryAction = "Manage access",
                    onSecondaryAction = { openHealthConnectSettings(context) },
                )
                SleepDataAccess.AVAILABLE -> Unit
            }
        }
        if (isDebuggable) {
            item {
                DemoDataCard(
                    active = state.isDemo,
                    onPreview = vm::loadDemoSleepTracker,
                    onExit = vm::refreshSleepTracker,
                )
            }
        }
        state.summary?.let { summary ->
            if (summary.nights.isNotEmpty()) {
                val selectedNight = summary.nights.firstOrNull { it.period.id == selectedNightId } ?: summary.nights.first()
                item { NightDetailCard(selectedNight, selectedNight.period.id == summary.nights.first().period.id) }
                item {
                    SleepTrendCard(
                        summary = summary,
                        selectedNightId = selectedNight.period.id,
                        onSelectNight = { selectedNightId = it.period.id },
                    )
                }
                if (summary.naps.isNotEmpty()) item { NapsCard(summary.naps) }
                item { AudiobookSleepCard(summary) }
                summary.comparison?.let { comparison ->
                    item { ListeningComparisonCard(comparison) }
                }
                item {
                    SourceAndPrivacyCard(selectedNight.period.sourceName, state.isDemo) {
                        openHealthConnectSettings(context)
                    }
                }
            } else {
                if (state.access == SleepDataAccess.AVAILABLE) item { EmptySleepCard() }
                item { ListeningOverviewCard(summary.listeningOverview) }
            }
        }
        item {
            Text(
                "Sleep stages are estimates from your connected source. Enve shows associations in your own history, not causes, diagnoses, or medical advice.",
                style = HearthText.Caption,
                color = Hearth.palette.textTertiary,
            )
        }
    }
}

@Composable
private fun DemoDataCard(active: Boolean, onPreview: () -> Unit, onExit: () -> Unit) {
    SleepCard {
        Overline("Debug preview")
        Spacer(Modifier.size(Hearth.Spacing.S))
        Text(
            if (active) "Showing fabricated sleep and audiobook history. Nothing was written to Health Connect."
            else "Preview two weeks of fabricated stages, naps, trends, and audiobook correlations.",
            style = HearthText.Body,
            color = Hearth.palette.textSecondary,
        )
        Spacer(Modifier.size(Hearth.Spacing.L))
        SleepAction(if (active) "Exit demo" else "Preview demo data", if (active) onExit else onPreview)
    }
}

@Composable
private fun AccessCard(
    title: String,
    body: String,
    action: String? = null,
    onAction: () -> Unit = {},
    secondaryAction: String? = null,
    onSecondaryAction: () -> Unit = {},
) {
    SleepCard {
        Text(title, style = hearthDisplay(22.sp, FontWeight.SemiBold), color = Hearth.palette.text)
        Spacer(Modifier.size(Hearth.Spacing.S))
        Text(body, style = HearthText.Body, color = Hearth.palette.textSecondary)
        action?.let {
            Spacer(Modifier.size(Hearth.Spacing.L))
            SleepAction(it, onAction)
        }
        secondaryAction?.let {
            Spacer(Modifier.size(Hearth.Spacing.S))
            Text(
                it,
                style = HearthText.Label,
                color = Hearth.palette.ember,
                modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onSecondaryAction)
                    .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
            )
        }
    }
}

@Composable
private fun NightDetailCard(night: SleepNightInsight, isLatest: Boolean) {
    val period = night.period
    SleepCard {
        Overline(if (isLatest) "Last night" else "Night detail")
        Spacer(Modifier.size(Hearth.Spacing.S))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            Text(formatDuration(period.totalSleepMs), style = hearthDisplay(36.sp, FontWeight.SemiBold), color = Hearth.palette.text)
            Spacer(Modifier.weight(1f))
            Text(formatDate(period.endTimeMs), style = HearthText.Caption, color = Hearth.palette.textTertiary)
        }
        Spacer(Modifier.size(Hearth.Spacing.L))
        StageTimeline(period)
        Spacer(Modifier.size(Hearth.Spacing.L))
        StageStats(period)
        Spacer(Modifier.size(Hearth.Spacing.L))
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            MetricChip("Bedtime", formatTime(period.startTimeMs))
            MetricChip("Wake", formatTime(period.endTimeMs))
            period.latencyMs?.let { MetricChip("Latency", formatDuration(it)) }
            period.efficiency?.let { MetricChip("Efficiency", "${(it * 100).roundToInt()}%") }
            MetricChip("Awakenings", period.awakenings.toString())
        }
        night.listening?.let { listening ->
            Spacer(Modifier.size(Hearth.Spacing.L))
            Box(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Inner))
                    .background(Hearth.palette.emberSoft).padding(Hearth.Spacing.L),
            ) {
                Column {
                    Overline("Audiobook wind-down")
                    Spacer(Modifier.size(Hearth.Spacing.XS))
                    Text(listening.bookTitle, style = HearthText.Label, color = Hearth.palette.text)
                    Text(
                        buildString {
                            append("${formatDuration(listening.listeningBeforeSleepMs)} before sleep")
                            listening.gapToSleepMs?.let { append(" · ${formatDuration(it)} gap") }
                            if (listening.playbackAfterSleepMs > 0) append(" · ${formatDuration(listening.playbackAfterSleepMs)} after onset")
                        },
                        style = HearthText.Caption,
                        color = Hearth.palette.textSecondary,
                    )
                }
            }
        }
    }
}

@Composable
private fun StageTimeline(period: SleepPeriod) {
    val palette = Hearth.palette
    val visible = period.stages.filter { it.endTimeMs > it.startTimeMs }
    if (visible.isEmpty()) {
        Text("No stage timeline was recorded.", style = HearthText.Caption, color = palette.textTertiary)
        return
    }
    Row(
        Modifier.fillMaxWidth().height(18.dp).clip(RoundedCornerShape(9.dp)).background(palette.bgSunken),
    ) {
        visible.forEach { stage ->
            Box(
                Modifier.weight((stage.endTimeMs - stage.startTimeMs).coerceAtLeast(1L).toFloat())
                    .height(18.dp).background(stageColor(stage.kind)),
            )
        }
    }
}

@Composable
private fun StageStats(period: SleepPeriod) {
    val order = listOf(
        SleepStageKind.AWAKE to "Awake",
        SleepStageKind.REM to "REM",
        SleepStageKind.LIGHT to "Light",
        SleepStageKind.DEEP to "Deep",
        SleepStageKind.ASLEEP to "Asleep",
    )
    val present = order.filter { (kind, _) -> (period.stageDurationsMs[kind] ?: 0L) > 0L }
    if (present.isEmpty()) return
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        present.forEach { (kind, label) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(8.dp).clip(RoundedCornerShape(50)).background(stageColor(kind)))
                Spacer(Modifier.size(Hearth.Spacing.S))
                Column {
                    Text(label, style = HearthText.Caption, color = Hearth.palette.textTertiary)
                    Text(formatDuration(period.stageDurationsMs[kind] ?: 0L), style = HearthText.Label, color = Hearth.palette.text)
                }
            }
        }
    }
}

@Composable
private fun SleepTrendCard(
    summary: SleepInsightsSummary,
    selectedNightId: String,
    onSelectNight: (SleepNightInsight) -> Unit,
) {
    val nights = summary.nights.take(14).reversed()
    val max = nights.maxOfOrNull { it.period.totalSleepMs }?.coerceAtLeast(1L) ?: 1L
    SleepCard {
        Overline("14-night rhythm")
        Spacer(Modifier.size(Hearth.Spacing.M))
        Row(
            Modifier.fillMaxWidth().height(92.dp),
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
            verticalAlignment = Alignment.Bottom,
        ) {
            nights.forEach { night ->
                val height = (night.period.totalSleepMs.toFloat() / max * 82).coerceAtLeast(8f).dp
                Box(
                    Modifier.weight(1f).height(height).clip(RoundedCornerShape(5.dp))
                        .background(
                            when {
                                night.period.id == selectedNightId -> Hearth.palette.ember
                                night.hadBedtimeListening -> Hearth.palette.statusWarn
                                else -> Hearth.palette.textTertiary
                            },
                        )
                        .semantics {
                            contentDescription = "${formatDate(night.period.endTimeMs)}, ${formatDuration(night.period.totalSleepMs)} sleep"
                        }
                        .clickable { onSelectNight(night) },
                )
            }
        }
        Spacer(Modifier.size(Hearth.Spacing.M))
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            summary.averageSleepMs?.let { MetricChip("Average sleep", formatDuration(it)) }
            summary.averageBedtimeOffsetMinutes?.let { MetricChip("Average bedtime", formatOffset(it)) }
            summary.averageWakeOffsetMinutes?.let { MetricChip("Average wake", formatOffset(it)) }
            summary.scheduleConsistencyMinutes?.let { MetricChip("Schedule variation", "±${it}m") }
            if (summary.naps.isNotEmpty()) MetricChip("Naps", summary.naps.size.toString())
        }
        Spacer(Modifier.size(Hearth.Spacing.S))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).clip(RoundedCornerShape(50)).background(Hearth.palette.statusWarn))
            Spacer(Modifier.size(Hearth.Spacing.XS))
            Text("Bedtime audiobook", style = HearthText.Caption, color = Hearth.palette.textTertiary)
        }
    }
}

@Composable
private fun NapsCard(naps: List<SleepPeriod>) {
    SleepCard {
        Overline("Naps")
        Spacer(Modifier.size(Hearth.Spacing.S))
        naps.take(5).forEach { nap ->
            Row(Modifier.fillMaxWidth().padding(vertical = Hearth.Spacing.S), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(formatDate(nap.startTimeMs), style = HearthText.Label, color = Hearth.palette.text)
                    Text("${formatTime(nap.startTimeMs)} – ${formatTime(nap.endTimeMs)}", style = HearthText.Caption, color = Hearth.palette.textTertiary)
                }
                Text(formatDuration(nap.totalSleepMs), style = HearthText.Label, color = Hearth.palette.ember)
            }
        }
    }
}

@Composable
private fun AudiobookSleepCard(summary: SleepInsightsSummary) {
    SleepCard {
        Overline("Audiobook patterns")
        Spacer(Modifier.size(Hearth.Spacing.M))
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            MetricChip("Matched nights", summary.matchedNights.toString())
            summary.averageBedtimeListeningMs?.let { MetricChip("Average wind-down", formatDuration(it)) }
            summary.averagePlaybackAfterSleepMs?.let { MetricChip("Average after onset", formatDuration(it)) }
        }
        summary.topBedtimeBookTitle?.let {
            Spacer(Modifier.size(Hearth.Spacing.L))
            Text("Most-listened bedtime book", style = HearthText.Caption, color = Hearth.palette.textTertiary)
            Text(it, style = HearthText.Label, color = Hearth.palette.text)
        }
    }
}

@Composable
private fun ListeningComparisonCard(comparison: SleepListeningComparison) {
    SleepCard {
        Overline("Listening vs. no listening")
        Spacer(Modifier.size(Hearth.Spacing.S))
        Text(
            "Personal averages across ${comparison.nightsWithListening} listening and ${comparison.nightsWithoutListening} non-listening nights.",
            style = HearthText.Caption,
            color = Hearth.palette.textSecondary,
        )
        Spacer(Modifier.size(Hearth.Spacing.L))
        ComparisonRow("Total sleep", formatDuration(comparison.averageSleepWithMs), formatDuration(comparison.averageSleepWithoutMs))
        if (comparison.averageLatencyWithMs != null && comparison.averageLatencyWithoutMs != null) {
            ComparisonRow("Latency", formatDuration(comparison.averageLatencyWithMs), formatDuration(comparison.averageLatencyWithoutMs))
        }
        if (comparison.averageEfficiencyWith != null && comparison.averageEfficiencyWithout != null) {
            ComparisonRow("Efficiency", formatPercent(comparison.averageEfficiencyWith), formatPercent(comparison.averageEfficiencyWithout))
        }
        if (comparison.averageRemWith != null && comparison.averageRemWithout != null) {
            ComparisonRow("REM", formatPercent(comparison.averageRemWith), formatPercent(comparison.averageRemWithout))
        }
        if (comparison.averageDeepWith != null && comparison.averageDeepWithout != null) {
            ComparisonRow("Deep", formatPercent(comparison.averageDeepWith), formatPercent(comparison.averageDeepWithout))
        }
    }
}

@Composable
private fun ComparisonRow(label: String, with: String, without: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = Hearth.Spacing.S), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = HearthText.Body, color = Hearth.palette.text, modifier = Modifier.weight(1f))
        Column(horizontalAlignment = Alignment.End) {
            Text(with, style = HearthText.Label, color = Hearth.palette.ember)
            Text("with listening", style = HearthText.Caption, color = Hearth.palette.textTertiary)
        }
        Spacer(Modifier.size(Hearth.Spacing.XL))
        Column(horizontalAlignment = Alignment.End) {
            Text(without, style = HearthText.Label, color = Hearth.palette.textSecondary)
            Text("without", style = HearthText.Caption, color = Hearth.palette.textTertiary)
        }
    }
}

@Composable
private fun EmptySleepCard() {
    AccessCard(
        title = "No recorded sleep yet",
        body = "Health Connect is connected, but no sleep sessions were found in the last 30 days. Sync your watch, ring, or sleep app and try again.",
    )
}

@Composable
private fun ListeningOverviewCard(overview: BedtimeListeningOverview) {
    SleepCard {
        Overline("Last 30 days in Enve")
        Spacer(Modifier.size(Hearth.Spacing.M))
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            MetricChip("Bedtime nights", overview.nights.toString())
            MetricChip("Night listening", formatDuration(overview.totalListeningMs))
            overview.averageListeningMs?.let { MetricChip("Average wind-down", formatDuration(it)) }
        }
        overview.topBookTitle?.let {
            Spacer(Modifier.size(Hearth.Spacing.L))
            Text("Top bedtime book", style = HearthText.Caption, color = Hearth.palette.textTertiary)
            Text(it, style = HearthText.Label, color = Hearth.palette.text)
        }
    }
}

@Composable
private fun SourceAndPrivacyCard(sourceName: String, isDemo: Boolean, onManage: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Inner)).background(Hearth.palette.bgSunken)
            .padding(Hearth.Spacing.L),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("Sleep data from $sourceName", style = HearthText.Label, color = Hearth.palette.text)
            Text(
                if (isDemo) "Generated locally · not saved to Health Connect"
                else "Read through Health Connect · processed on device",
                style = HearthText.Caption,
                color = Hearth.palette.textTertiary,
            )
        }
        if (!isDemo) {
            Text(
                "Manage",
                style = HearthText.Label,
                color = Hearth.palette.ember,
                modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onManage)
                    .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
            )
        }
    }
}

@Composable
private fun MetricChip(label: String, value: String) {
    Column(
        Modifier.clip(RoundedCornerShape(Hearth.Radius.Inner)).background(Hearth.palette.bgSunken)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
    ) {
        Text(label, style = HearthText.Caption, color = Hearth.palette.textTertiary)
        Text(value, style = HearthText.Label, color = Hearth.palette.text)
    }
}

@Composable
private fun SleepCard(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Card)).background(Hearth.palette.bgElevated)
            .padding(Hearth.Spacing.L),
        content = content,
    )
}

@Composable
private fun SleepAction(label: String, onClick: () -> Unit) {
    Box(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(50)).background(Hearth.palette.ember)
            .clickable(onClick = onClick).padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = HearthText.Label, color = Hearth.palette.readableOnEmber)
    }
}

@Composable
private fun stageColor(kind: SleepStageKind): Color = when (kind) {
    SleepStageKind.AWAKE -> Hearth.palette.statusWarn
    SleepStageKind.REM -> Hearth.palette.ember
    SleepStageKind.LIGHT -> Hearth.palette.textSecondary
    SleepStageKind.DEEP -> Hearth.palette.statusOK
    SleepStageKind.ASLEEP -> Hearth.palette.textTertiary
    SleepStageKind.UNKNOWN -> Hearth.palette.hairline
}

private fun openHealthConnectSettings(context: Context) {
    context.startActivity(Intent(HealthConnectClient.ACTION_HEALTH_CONNECT_SETTINGS))
}

private fun openHealthConnectStore(context: Context) {
    try {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.google.android.apps.healthdata")))
    } catch (_: ActivityNotFoundException) {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=com.google.android.apps.healthdata")))
    }
}

private fun formatDuration(milliseconds: Long): String {
    val totalMinutes = (milliseconds / 60_000L).coerceAtLeast(0L)
    val hours = totalMinutes / 60
    val minutes = totalMinutes % 60
    return when {
        hours > 0 && minutes > 0 -> "${hours}h ${minutes}m"
        hours > 0 -> "${hours}h"
        else -> "${minutes}m"
    }
}

private fun formatTime(milliseconds: Long): String =
    Instant.ofEpochMilli(milliseconds).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT))

private fun formatDate(milliseconds: Long): String =
    Instant.ofEpochMilli(milliseconds).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("EEE, MMM d"))

private fun formatOffset(minutesAfterNoon: Int): String =
    LocalTime.NOON.plusMinutes(minutesAfterNoon.toLong()).format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT))

private fun formatPercent(value: Double): String = "${(value * 100).roundToInt()}%"
