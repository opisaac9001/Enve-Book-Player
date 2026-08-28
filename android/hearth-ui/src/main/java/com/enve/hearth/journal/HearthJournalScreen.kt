package com.enve.hearth.journal

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.LibraryBooks
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Book
import androidx.compose.material.icons.outlined.Bedtime
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Headphones
import androidx.compose.material.icons.outlined.Insights
import androidx.compose.material.icons.outlined.QueryStats
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.WorkspacePremium
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthPalette
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.ShelfHeader
import com.enve.hearth.design.hearthDisplay

@Composable
fun HearthJournalScreen(
    onSelectBook: (Book) -> Unit,
    onOpenCompletions: () -> Unit,
    onOpenInsights: () -> Unit,
    onOpenStatsHub: () -> Unit,
    onOpenSleep: () -> Unit,
    onOpenSettings: () -> Unit = {},
) {
    val vm: HearthJournalViewModel = hiltViewModel()
    val stats by vm.stats.collectAsStateWithLifecycle()
    val mantel by vm.mantel.collectAsStateWithLifecycle()
    val heatmap by vm.heatmap.collectAsStateWithLifecycle()
    val achievements by vm.achievements.collectAsStateWithLifecycle()
    val palette = Hearth.palette

    LazyColumn(
        Modifier.fillMaxSize().background(palette.bg),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = LocalMantelInset.current + Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXL),
    ) {
        item {
            Row(
                Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.L),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column {
                    Overline("Your reading life")
                    Text("Journal", style = HearthText.ScreenTitle, color = palette.text)
                }
                Box(
                    Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(palette.bgElevated)
                        .border(1.dp, palette.hairline, CircleShape)
                        .clickable(onClick = onOpenSettings),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Outlined.Settings,
                        contentDescription = "Settings",
                        tint = palette.textSecondary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }

        item {
            ThisWeek(stats)
        }

        if (heatmap.any { it > 0f }) {
            item {
                PastYear(heatmap)
            }
        }

        if (mantel.isNotEmpty()) {
            item {
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                    ShelfHeader("The Mantel", modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL))
                    LazyRow(
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Hearth.Spacing.XL),
                        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
                    ) {
                        items(mantel, key = { it.id + (it.connectionId ?: "") }) { book ->
                            CoverTile(model = book.coverUrl, modifier = Modifier.width(112.dp).clickable { onSelectBook(book) })
                        }
                    }
                }
            }
        }

        item { CloserLook(stats, onOpenCompletions, onOpenInsights, onOpenStatsHub, onOpenSleep) }

        if (achievements.available > 0) {
            item { MilestonesSection(achievements) }
        }

    }
}

@Composable
private fun MilestonesSection(achievements: JournalAchievements) {
    val palette = Hearth.palette
    val shown = (achievements.topEarned.take(2) + achievements.nextUp.take(3)).take(4)
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        ShelfHeader("Your milestones", modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL))
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = Hearth.Spacing.XL)
                .clip(RoundedCornerShape(Hearth.Radius.Card))
                .background(palette.bgElevated)
                .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card))
                .padding(Hearth.Spacing.L),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        ) {
            Text(
                "${achievements.earned} of ${achievements.available} earned across every source",
                style = HearthText.Caption,
                color = palette.textSecondary,
            )
            shown.forEach { achievement ->
                MilestoneRow(achievement)
            }
        }
    }
}

@Composable
private fun MilestoneRow(achievement: JournalAchievement) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            Icon(
                if (achievement.earned) Icons.Filled.CheckCircle else Icons.Outlined.WorkspacePremium,
                contentDescription = null,
                tint = if (achievement.earned) palette.ember else palette.textTertiary,
                modifier = Modifier.size(18.dp),
            )
            Text(achievement.name, style = HearthText.Label, color = palette.text, modifier = Modifier.weight(1f))
            Text(
                "${achievement.progress} / ${achievement.threshold}",
                style = HearthText.Caption,
                color = palette.textSecondary,
            )
        }
        Text(achievement.description, style = HearthText.Caption, color = palette.textTertiary)
        val track = RoundedCornerShape(50)
        Box(
            Modifier
                .fillMaxWidth()
                .size(height = 4.dp, width = 1.dp)
                .clip(track)
                .background(if (eink.active) palette.bg else palette.hairline)
                .then(if (eink.active) Modifier.border(1.dp, palette.text, track) else Modifier),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(achievement.fraction)
                    .fillMaxHeight()
                    .clip(track)
                    .background(if (eink.active) palette.text else palette.ember),
            )
        }
    }
}

@Composable
private fun ThisWeek(stats: JournalStats) {
    val palette = Hearth.palette
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L)) {
        Overline("This week")
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXL)) {
            WeekMetric("${stats.listeningMinutes}m", "Listening", Modifier.weight(1f))
            WeekMetric("${stats.readingMinutes}m", "Reading", Modifier.weight(1f))
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            Box(Modifier.size(10.dp).clip(RoundedCornerShape(50)).background(palette.ember))
            Text(
                if (stats.streakNights == 1) "1 night running" else "${stats.streakNights} nights running",
                style = hearthDisplay(17.sp, FontWeight.SemiBold),
                color = palette.text,
            )
        }
    }
}

@Composable
private fun WeekMetric(value: String, label: String, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
        Text(value, style = hearthDisplay(34.sp, FontWeight.Bold), color = Hearth.palette.text)
        Text(label, style = HearthText.Overline, color = Hearth.palette.textSecondary)
    }
}

@Composable
private fun PastYear(heatmap: List<Float>) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val monochrome = HearthPalette.eink()
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        Overline("The past year")
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            repeat(7) { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    repeat(52) { column ->
                        val intensity = heatmap.getOrElse(column * 7 + row) { 0f }
                        val shape = RoundedCornerShape(1.dp)
                        val fill = when {
                            !eink.active && intensity <= 0f -> palette.bgElevated
                            !eink.active -> palette.ember.copy(alpha = 0.3f + 0.7f * intensity)
                            intensity <= 0f -> palette.bg
                            palette.isInk && intensity < 0.34f -> lerp(monochrome.text, monochrome.bg, 0.35f)
                            palette.isInk && intensity < 0.67f -> lerp(monochrome.text, monochrome.bg, 0.7f)
                            palette.isInk -> monochrome.bg
                            intensity < 0.34f -> lerp(monochrome.bg, monochrome.text, 0.35f)
                            intensity < 0.67f -> lerp(monochrome.bg, monochrome.text, 0.7f)
                            else -> monochrome.text
                        }
                        Box(
                            Modifier
                                .size(5.dp)
                                .clip(shape)
                                .background(fill)
                                .then(
                                    if (eink.active) {
                                        Modifier.border(
                                            1.dp,
                                            if (palette.isInk) monochrome.bg else monochrome.text,
                                            shape,
                                        )
                                    } else {
                                        Modifier
                                    },
                                ),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CloserLook(
    stats: JournalStats,
    onOpenCompletions: () -> Unit,
    onOpenInsights: () -> Unit,
    onOpenStatsHub: () -> Unit,
    onOpenSleep: () -> Unit,
) {
    val palette = Hearth.palette
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        ShelfHeader("A closer look", modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL))
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = Hearth.Spacing.XL)
                .clip(RoundedCornerShape(Hearth.Radius.Card))
                .background(palette.bgElevated)
                .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card)),
        ) {
            JournalLinkRow(
                Icons.Outlined.QueryStats,
                "Stats Hub",
                "All services, or one at a time",
                onClick = onOpenStatsHub,
            )
            JournalDivider()
            JournalLinkRow(
                Icons.Outlined.Insights,
                "Insights",
                "Your rhythm, favorites, and year in review",
                onClick = onOpenInsights,
            )
            JournalDivider()
            JournalLinkRow(Icons.Outlined.Headphones, "Listening", "${stats.audiobooks} audiobooks in your library")
            JournalDivider()
            JournalLinkRow(Icons.Outlined.Book, "Reading", "${stats.ebooks} ebooks and pages turned")
            JournalDivider()
            JournalLinkRow(
                Icons.Outlined.Bedtime,
                "Sleep stats",
                "Stages, trends, and bedtime listening patterns",
                onClick = onOpenSleep,
            )
            JournalDivider()
            JournalLinkRow(
                Icons.Outlined.WorkspacePremium,
                "Finished",
                "${stats.finished} books on the mantel",
                onClick = onOpenCompletions,
            )
            JournalDivider()
            JournalLinkRow(Icons.AutoMirrored.Outlined.LibraryBooks, "Library", "${stats.total} books across ${stats.authors} authors")
        }
    }
}

@Composable
private fun JournalLinkRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    onClick: (() -> Unit)? = null,
) {
    val palette = Hearth.palette
    Row(
        Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Icon(icon, contentDescription = null, tint = palette.ember, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
            Text(title, style = HearthText.Label, color = palette.text)
            Text(subtitle, style = HearthText.Caption, color = palette.textSecondary)
        }
        if (onClick != null) {
            Icon(Icons.Outlined.ChevronRight, contentDescription = null, tint = palette.textTertiary, modifier = Modifier.size(22.dp))
        }
    }
}

@Composable
private fun JournalDivider() {
    Spacer(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Hearth.Spacing.L)
            .size(height = 1.dp, width = 1.dp)
            .background(Hearth.palette.hairline),
    )
}
