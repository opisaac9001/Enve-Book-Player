package com.enve.hearth.journal

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.QueryStats
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.hearthDisplay
import com.enve.engine.servertools.ServerStatGroup
import com.enve.engine.servertools.ServerFeature
import androidx.compose.ui.unit.sp

@Composable
fun HearthStatsHubScreen(
    onBack: () -> Unit,
    onOpenBookOrbit: () -> Unit,
) {
    val vm: HearthJournalViewModel = hiltViewModel()
    val books by vm.books.collectAsStateWithLifecycle()
    val sessions by vm.sessions.collectAsStateWithLifecycle()
    val targets by vm.statsTargets.collectAsStateWithLifecycle()
    val remoteStats by vm.serverStats.collectAsStateWithLifecycle()
    val loadingRemote by vm.loadingServerStats.collectAsStateWithLifecycle()
    val sources = (books.map { it.source } + sessions.map { it.source } + targets.filter { it.enabled }.map { it.source })
        .distinct()
        .sortedBy(BookSource::displayName)
    var selected by remember { mutableStateOf<BookSource?>(null) }
    val selectedBooks = selected?.let { source -> books.filter { it.source == source } } ?: books
    val selectedSessions = selected?.let { source -> sessions.filter { it.source == source } } ?: sessions
    val stats = JournalActivityPolicy.stats(selectedBooks, selectedSessions)
    val palette = Hearth.palette
    var menuOpen by remember { mutableStateOf(false) }

    LaunchedEffect(selected, targets) {
        selected?.let(vm::loadServerStats)
    }

    Column(Modifier.fillMaxSize().background(palette.bg)) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(48.dp).clip(CircleShape).clickable(onClick = onBack),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back", tint = palette.text)
            }
            Column(Modifier.weight(1f)) {
                Overline("Every source, in one place")
                Text("Stats Hub", style = HearthText.ScreenTitle, color = palette.text)
            }
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.M),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
        ) {
            item {
                Box {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(Hearth.Radius.Card))
                            .background(palette.bgElevated)
                            .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card))
                            .clickable { menuOpen = true }
                            .padding(Hearth.Spacing.L),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
                    ) {
                        Icon(Icons.Outlined.QueryStats, contentDescription = null, tint = palette.ember)
                        Text(selected?.displayName ?: "All services", style = HearthText.Label, color = palette.text, modifier = Modifier.weight(1f))
                        Icon(Icons.Outlined.ExpandMore, contentDescription = "Choose service", tint = palette.textSecondary)
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(text = { Text("All services") }, onClick = { selected = null; menuOpen = false })
                        sources.forEach { source ->
                            DropdownMenuItem(text = { Text(source.displayName) }, onClick = { selected = source; menuOpen = false })
                        }
                    }
                }
            }
            val richGroups = selected?.let(remoteStats::get).orEmpty()
            val hasRemoteStats = selected != null && targets.any {
                it.enabled && it.source == selected && ServerFeature.STATS in it.features
            }
            if (richGroups.isEmpty() && (!hasRemoteStats || selected !in loadingRemote)) {
                item { StatsCard(selected?.displayName ?: "All services", stats) }
            }
            if (selected in loadingRemote) {
                item { LoadingStatsCard(selected?.displayName ?: "service") }
            } else {
                richGroups.forEach { group -> item(group.title) { RichStatsCard(group) } }
            }
            if (selected == BookSource.BOOKORBIT) {
                item {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(Hearth.Radius.Card))
                            .background(palette.bgElevated)
                            .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card))
                            .clickable(onClick = onOpenBookOrbit)
                            .padding(Hearth.Spacing.L),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
                    ) {
                        Icon(Icons.Outlined.QueryStats, contentDescription = null, tint = palette.ember)
                        Column(Modifier.weight(1f)) {
                            Text("Full BookOrbit insights", style = HearthText.Label, color = palette.text)
                            Text("Goals, reading rhythm, achievements, and highlights", style = HearthText.Caption, color = palette.textSecondary)
                        }
                        Icon(Icons.Outlined.ChevronRight, contentDescription = null, tint = palette.textSecondary)
                    }
                }
            }
            if (richGroups.isEmpty()) item { ActivityCard(selectedSessions) }
        }
    }
}

@Composable
private fun StatsCard(title: String, stats: JournalStats) {
    val palette = Hearth.palette
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Card)).background(palette.bgElevated)
            .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card)).padding(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Overline(title)
        StatRow("Listening this week", "${stats.listeningMinutes}m")
        StatRow("Reading this week", "${stats.readingMinutes}m")
        StatRow("Finished", stats.finished.toString())
        StatRow("Underway", stats.reading.toString())
        StatRow("Books", stats.total.toString())
        StatRow("Streak", if (stats.streakNights == 1) "1 night" else "${stats.streakNights} nights")
    }
}

@Composable
private fun LoadingStatsCard(source: String) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Card)).background(palette.bgElevated)
            .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card)).padding(Hearth.Spacing.L),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        CircularProgressIndicator(color = palette.ember, modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
        Text("Asking $source for the full story…", style = HearthText.Caption, color = palette.textSecondary)
    }
}

@Composable
private fun RichStatsCard(group: ServerStatGroup) {
    val palette = Hearth.palette
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Card)).background(palette.bgElevated)
            .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card)).padding(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
    ) {
        Overline(group.title)
        group.stats.chunked(2).forEach { row ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.L)) {
                row.forEach { stat ->
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS)) {
                        Text(stat.value, style = hearthDisplay(24.sp), color = palette.text, maxLines = 1)
                        Text(stat.label, style = HearthText.Caption, color = palette.textSecondary)
                        stat.detail?.let { Text(it, style = HearthText.Caption, color = palette.textTertiary) }
                    }
                }
                if (row.size == 1) Box(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun ActivityCard(sessions: List<HistorySession>) {
    val palette = Hearth.palette
    val minutes = (sessions.sumOf(HistorySession::activeDurationSeconds) / 60L)
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Card)).background(palette.bgElevated)
            .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card)).padding(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Overline("Activity")
        Text(
            if (sessions.isEmpty()) "No sessions reported by this service yet" else "${sessions.size} sessions · $minutes minutes recorded",
            style = HearthText.Label,
            color = if (sessions.isEmpty()) palette.textSecondary else palette.text,
        )
    }
}

@Composable
private fun StatRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = HearthText.Caption, color = Hearth.palette.textSecondary)
        Text(value, style = HearthText.Label, color = Hearth.palette.text)
    }
}
