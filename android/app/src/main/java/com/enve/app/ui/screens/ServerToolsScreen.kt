package com.enve.app.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AdminPanelSettings
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material.icons.filled.History
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.SettingsSectionHeader
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.ServerToolsViewModel
import com.enve.core.data.model.BookSource
import com.enve.engine.servertools.ServerAchievementSummary
import com.enve.engine.servertools.ServerBookmark
import com.enve.engine.servertools.ServerHighlight
import com.enve.engine.servertools.ServerHistoryEntry
import com.enve.engine.servertools.ServerStatGroup
import com.enve.engine.servertools.ServerToolsTarget
import com.enve.hearth.design.hearthDisplay
import java.text.DateFormat
import java.util.Date

@Composable
fun ServerToolsScreen(
    onBack: () -> Unit,
    onOpenAdmin: (BookSource, String) -> Unit,
    viewModel: ServerToolsViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsState()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)
    val target = state.target

    SettingsScreenLayout(animatedBackground = EnveTheme.dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .statusBarsPadding()
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = onBack)
                Column(modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics))) {
                    Text(
                        text = target?.name ?: "Server tools",
                        color = colors.primaryText,
                        style = hearthDisplay(22.sp),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    target?.let {
                        Text(
                            text = it.serverUrl,
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }

            if (target != null && !target.enabled) {
                NoticeCard("This connection is paused. Resume it in the Server Hub to load its reader features.")
            }

            when {
                state.loading -> LoadingCard()
                state.unreachable -> NoticeCard(
                    text = "Couldn't reach this server. Check that it is online and try again.",
                    actionLabel = "Retry",
                    onAction = viewModel::refresh,
                )
                !state.hasAnyContent -> NoticeCard(
                    text = if (target?.features.orEmpty().isEmpty()) {
                        "Enve doesn't offer personal reader features for this source yet."
                    } else {
                        "This server didn't return any of the reader features Enve supports."
                    },
                    actionLabel = "Retry",
                    onAction = viewModel::refresh,
                )
            }

            state.stats.forEach { group ->
                StatGroupCard(group, dividerColor)
            }

            state.achievements?.let { achievements ->
                AchievementsCard(achievements, dividerColor)
            }

            if (state.highlights.isNotEmpty()) {
                HighlightsCard(state.highlights, dividerColor)
            }

            if (state.bookmarks.isNotEmpty()) {
                BookmarksCard(state.bookmarks, dividerColor)
            }

            if (state.history.isNotEmpty()) {
                HistoryCard(state.history, dividerColor)
            }

            if (target != null && hasAdminHub(target)) {
                val storyteller = target.source == BookSource.STORYTELLER
                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    SettingsSectionHeader(title = if (storyteller) "Server hub" else "Administration")
                    ToolRow(
                        icon = Icons.Default.AdminPanelSettings,
                        title = "Manage this server",
                        subtitle = if (storyteller) {
                            "Shelves, alignment quality, and readaloud processing"
                        } else {
                            "Users, libraries, and server maintenance"
                        },
                        onClick = { onOpenAdmin(target.source, target.connectionId) },
                    )
                }
            }

            Spacer(Modifier.height(80.dp.scaled(metrics)))
        }
    }
}

private fun hasAdminHub(target: ServerToolsTarget): Boolean = when (target.source) {
    BookSource.KOMGA, BookSource.SILO -> target.isAdmin
    BookSource.STORYTELLER -> true
    else -> false
}

@Composable
private fun StatGroupCard(group: ServerStatGroup, dividerColor: Color) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = group.title)
        group.stats.forEachIndexed { index, stat ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(stat.label, color = colors.primaryText, fontSize = DS.FontSize.Body.scaled(metrics))
                    stat.detail?.let {
                        Text(it, color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                    }
                }
                Text(
                    stat.value,
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Body.scaled(metrics),
                    fontWeight = FontWeight.SemiBold,
                )
            }
            if (index < group.stats.lastIndex) HorizontalDivider(color = dividerColor)
        }
    }
}

@Composable
private fun AchievementsCard(
    achievements: ServerAchievementSummary,
    dividerColor: Color,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val shown = achievements.achievements
        .sortedWith(compareBy({ !it.earned }, { it.name }))
        .take(8)
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(
            title = "Server achievements",
            subtitle = "${achievements.earned} of ${achievements.available} earned on this server",
        )
        shown.forEachIndexed { index, achievement ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        achievement.name,
                        color = if (achievement.earned) colors.primaryText else colors.secondaryText,
                        fontSize = DS.FontSize.Body.scaled(metrics),
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        achievement.description,
                        color = colors.tertiaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                val progress = achievement.progress
                val threshold = achievement.threshold
                Text(
                    text = when {
                        achievement.earned -> "Earned"
                        progress != null && threshold != null -> "${progress.toInt()} / ${threshold.toInt()}"
                        else -> "Locked"
                    },
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
            if (index < shown.lastIndex) HorizontalDivider(color = dividerColor)
        }
    }
}

@Composable
private fun HighlightsCard(
    highlights: List<ServerHighlight>,
    dividerColor: Color,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = "Highlights & notes", subtitle = "${highlights.size} most recent")
        highlights.forEachIndexed { index, highlight ->
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.FormatQuote,
                        contentDescription = null,
                        tint = colors.accent,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        listOfNotNull(highlight.bookTitle, highlight.chapterTitle).joinToString(" · ")
                            .ifBlank { "Highlight" },
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Text(
                    highlight.text,
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Body.scaled(metrics),
                    maxLines = 4,
                    overflow = TextOverflow.Ellipsis,
                )
                highlight.note?.let {
                    Text(it, color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics), maxLines = 3)
                }
                highlight.createdAtMs?.let {
                    Text(
                        DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(it)),
                        color = colors.tertiaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
            }
            if (index < highlights.lastIndex) HorizontalDivider(color = dividerColor)
        }
    }
}

@Composable
private fun BookmarksCard(
    bookmarks: List<ServerBookmark>,
    dividerColor: Color,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = "Bookmarks", subtitle = "${bookmarks.size} saved on this server")
        bookmarks.forEachIndexed { index, bookmark ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Default.Bookmark,
                    contentDescription = null,
                    tint = colors.accent,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        bookmark.label ?: "Bookmark",
                        color = colors.primaryText,
                        fontSize = DS.FontSize.Body.scaled(metrics),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    bookmark.bookTitle?.let {
                        Text(
                            it,
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                bookmark.positionSeconds?.let {
                    Text(
                        clockTime(it),
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
            }
            if (index < bookmarks.lastIndex) HorizontalDivider(color = dividerColor)
        }
    }
}

@Composable
private fun HistoryCard(
    history: List<ServerHistoryEntry>,
    dividerColor: Color,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = "Recent activity", subtitle = "Most recent first")
        history.forEachIndexed { index, entry ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Default.History,
                    contentDescription = null,
                    tint = colors.accent,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        entry.title,
                        color = colors.primaryText,
                        fontSize = DS.FontSize.Body.scaled(metrics),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    entry.subtitle?.let {
                        Text(
                            it,
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                entry.occurredAtMs?.let {
                    Text(
                        DateFormat.getDateInstance(DateFormat.SHORT).format(Date(it)),
                        color = colors.tertiaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
            }
            if (index < history.lastIndex) HorizontalDivider(color = dividerColor)
        }
    }
}

@Composable
private fun ToolRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = colors.accent,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = colors.primaryText, fontSize = DS.FontSize.Body.scaled(metrics), fontWeight = FontWeight.SemiBold)
            Text(subtitle, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
        }
    }
}

@Composable
private fun LoadingCard() {
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DS.Spacing.XL.scaled(metrics)),
            contentAlignment = Alignment.Center,
        ) {
            CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
        }
    }
}

@Composable
private fun NoticeCard(
    text: String,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DS.Spacing.LG.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = text,
                color = colors.secondaryText,
                fontSize = DS.FontSize.Body.scaled(metrics),
                modifier = Modifier.weight(1f),
            )
            if (actionLabel != null && onAction != null) {
                TextButton(onClick = onAction) { Text(actionLabel) }
            }
        }
    }
}

private fun clockTime(seconds: Long): String {
    val safe = seconds.coerceAtLeast(0L)
    val hours = safe / 3600
    val minutes = (safe % 3600) / 60
    val remainder = safe % 60
    return if (hours > 0L) {
        "%d:%02d:%02d".format(hours, minutes, remainder)
    } else {
        "%d:%02d".format(minutes, remainder)
    }
}
