package com.enve.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.automirrored.filled.ViewList
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.core.data.model.BookCardStyle
import com.enve.core.data.model.LibraryLayout
import com.enve.core.data.model.MergeAggressiveness
import com.enve.core.data.model.SubtitleHandling
import com.enve.core.data.model.TitleDisplayMode
import com.enve.core.data.util.LibraryDisplayTitleFormatter
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsHeroHeader
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.SettingsSectionHeader
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.LibraryViewModel
import com.enve.hearth.design.hearthDisplay

@Composable
fun LibraryDisplaySettingsScreen(
    onBack: () -> Unit,
    viewModel: LibraryViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsState()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)

    SettingsScreenLayout(animatedBackground = true) {
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
                Text(
                    text = "Library Display",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
            }

            SettingsHeroHeader(
                title = "Library Display",
                subtitle = "Control card style, title cleanup, subtitles, deduping, and layout.",
                badge = state.bookCardStyle.displayName,
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(
                    title = "Card Style",
                    subtitle = state.bookCardStyle.description,
                )
                BookCardStyle.entries.forEachIndexed { index, style ->
                    DisplayModeRow(
                        label = style.displayName,
                        example = style.description,
                        icon = iconForBookCardStyle(style),
                        selected = state.bookCardStyle == style,
                        accentColor = colors.accent,
                        onSelect = { viewModel.setBookCardStyle(style) },
                    )
                    if (index < BookCardStyle.entries.size - 1) {
                        HorizontalDivider(color = dividerColor)
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(
                    title = "Layout",
                    subtitle = "Pick the default grid density. You can always tweak this from the filter button on the Library tab.",
                )
                LibraryLayout.entries.forEachIndexed { index, layout ->
                    LayoutOptionRow(
                        layout = layout,
                        selected = state.layout == layout,
                        onSelect = { viewModel.setLayout(layout) },
                    )
                    if (index < LibraryLayout.entries.size - 1) {
                        HorizontalDivider(color = dividerColor)
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(
                    title = "Title Display",
                    subtitle = state.titleDisplayMode.description,
                )
                TitleDisplayMode.entries.forEachIndexed { index, mode ->
                    DisplayModeRow(
                        label = mode.displayName,
                        example = mode.example,
                        icon = iconForTitleMode(mode),
                        selected = state.titleDisplayMode == mode,
                        accentColor = colors.accent,
                        onSelect = { viewModel.setTitleDisplayMode(mode) },
                    )
                    if (index < TitleDisplayMode.entries.size - 1) {
                        HorizontalDivider(color = dividerColor)
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(
                    title = "Subtitles",
                    subtitle = state.subtitleHandling.example,
                )
                SubtitleHandling.entries.forEachIndexed { index, handling ->
                    DisplayModeRow(
                        label = handling.displayName,
                        example = handling.example,
                        icon = if (handling == SubtitleHandling.KEEP) Icons.Default.FormatQuote else Icons.Default.ContentCut,
                        selected = state.subtitleHandling == handling,
                        accentColor = colors.accent,
                        onSelect = { viewModel.setSubtitleHandling(handling) },
                    )
                    if (index < SubtitleHandling.entries.size - 1) {
                        HorizontalDivider(color = dividerColor)
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(
                    title = "Preview",
                    subtitle = "See how your settings affect displayed titles",
                )
                listOf(
                    "01 - The Way of Kings" to "Series prefix",
                    "Book 3 - Oathbringer" to "Book prefix",
                    "The Hobbit: An Unexpected Journey" to "With subtitle",
                ).forEachIndexed { index, (original, type) ->
                    TitlePreviewRow(
                        original = original,
                        type = type,
                        displayMode = state.titleDisplayMode,
                        subtitleHandling = state.subtitleHandling,
                    )
                    if (index < 2) {
                        HorizontalDivider(color = dividerColor, modifier = Modifier.padding(vertical = DS.Spacing.XS.scaled(metrics)))
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { viewModel.setShowAdvancedLibrarySettings(!state.showAdvancedLibrarySettings) }
                        .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                ) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(Color(0xFFF5921A).copy(alpha = 0.15f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Default.Settings, contentDescription = null, tint = Color(0xFFF5921A), modifier = Modifier.size(20.dp))
                    }
                    Text(
                        text = "Show Advanced Settings",
                        color = colors.primaryText,
                        fontSize = DS.FontSize.Body.scaled(metrics),
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = state.showAdvancedLibrarySettings,
                        onCheckedChange = { viewModel.setShowAdvancedLibrarySettings(it) },
                        colors = SwitchDefaults.colors(checkedThumbColor = Color.White, checkedTrackColor = colors.accent),
                    )
                }
            }

            AnimatedVisibility(visible = state.showAdvancedLibrarySettings) {
                Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics))) {

                    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                        SettingsSectionHeader(
                            title = "Duplicate Detection",
                            subtitle = state.mergeAggressiveness.description,
                        )
                        MergeAggressiveness.entries.forEachIndexed { index, aggressiveness ->
                            val color = aggressivenessColor(aggressiveness)
                            DisplayModeRow(
                                label = aggressiveness.displayName,
                                example = "Threshold: ${aggressiveness.threshold}%",
                                icon = iconForAggressiveness(aggressiveness),
                                selected = state.mergeAggressiveness == aggressiveness,
                                accentColor = color,
                                onSelect = { viewModel.setMergeAggressiveness(aggressiveness) },
                            )
                            if (index < MergeAggressiveness.entries.size - 1) {
                                HorizontalDivider(color = dividerColor)
                            }
                        }
                    }

                    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                        SettingsSectionHeader(
                            title = "Author & Narrator Grouping",
                            subtitle = "Higher values require closer matches; lower values group more aggressively.",
                        )
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = DS.Spacing.LG.scaled(metrics))
                                .padding(bottom = DS.Spacing.MD.scaled(metrics)),
                            verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = "Similarity Threshold",
                                    color = colors.secondaryText,
                                    fontSize = DS.FontSize.Body.scaled(metrics),
                                    modifier = Modifier.weight(1f),
                                )
                                Text(
                                    text = "${(state.authorGroupingThreshold * 100).toInt()}%",
                                    color = colors.accent,
                                    fontSize = DS.FontSize.Title3.scaled(metrics),
                                    fontWeight = FontWeight.Bold,
                                )
                            }
                            Slider(
                                value = state.authorGroupingThreshold,
                                onValueChange = { viewModel.setAuthorGroupingThreshold(it) },
                                valueRange = 0.70f..1.0f,
                                steps = 5,
                                colors = SliderDefaults.colors(thumbColor = colors.accent, activeTrackColor = colors.accent),
                            )
                            Row(modifier = Modifier.fillMaxWidth()) {
                                Column {
                                    Text("70%", color = colors.primaryText, fontSize = DS.FontSize.Caption.scaled(metrics), fontWeight = FontWeight.Medium)
                                    Text("Loose", color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                                }
                                Spacer(Modifier.weight(1f))
                                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                    Text("85%", color = colors.primaryText, fontSize = DS.FontSize.Caption.scaled(metrics), fontWeight = FontWeight.Medium)
                                    Text("Default", color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                                }
                                Spacer(Modifier.weight(1f))
                                Column(horizontalAlignment = Alignment.End) {
                                    Text("100%", color = colors.primaryText, fontSize = DS.FontSize.Caption.scaled(metrics), fontWeight = FontWeight.Medium)
                                    Text("Exact", color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                                }
                            }
                        }
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(
                    title = "Merge Library Cache",
                    subtitle = "Clear the local library index and rebuild from your connected sources.",
                )
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.LG.scaled(metrics))
                        .padding(bottom = DS.Spacing.MD.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                    ) {
                        Icon(
                            imageVector = Icons.Default.CheckCircle,
                            contentDescription = null,
                            tint = Color(0xFF6F8F6A),
                            modifier = Modifier.size(20.dp.scaled(metrics)),
                        )
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = if (state.totalBookCount > 0) "Cache Active" else "No cache yet",
                                color = colors.primaryText,
                                fontSize = DS.FontSize.Body.scaled(metrics),
                                fontWeight = FontWeight.Medium,
                            )
                            Text(
                                text = "${state.totalBookCount} books cached",
                                color = colors.tertiaryText,
                                fontSize = DS.FontSize.Caption.scaled(metrics),
                            )
                        }
                    }

                    Button(
                        onClick = { viewModel.forceLibraryCacheRebuild() },
                        enabled = !state.isRefreshing,
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = colors.accent,
                            contentColor = colors.onAccent,
                            disabledContainerColor = colors.secondaryBackground,
                            disabledContentColor = colors.tertiaryText,
                        ),
                    ) {
                        if (state.isRefreshing) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp.scaled(metrics)),
                                strokeWidth = 2.dp,
                                color = colors.tertiaryText,
                            )
                            Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
                        } else {
                            Icon(
                                imageVector = Icons.Default.Refresh,
                                contentDescription = null,
                                modifier = Modifier.size(18.dp.scaled(metrics)),
                            )
                            Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
                        }
                        Text(
                            text = if (state.isRefreshing) "Rebuilding..." else "Clear Cache & Rebuild",
                            fontSize = DS.FontSize.Subheadline.scaled(metrics),
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
            }

            Spacer(Modifier.height(80.dp.scaled(metrics)))
        }
    }
}

@Composable
private fun LayoutOptionRow(
    layout: LibraryLayout,
    selected: Boolean,
    onSelect: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onSelect)
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {
        Icon(
            imageVector = if (layout == LibraryLayout.LIST) Icons.AutoMirrored.Filled.ViewList else Icons.Default.GridView,
            contentDescription = null,
            tint = colors.accent,
            modifier = Modifier.size(20.dp),
        )
        Text(
            text = layout.displayName,
            color = colors.primaryText,
            fontSize = DS.FontSize.Body.scaled(metrics),
            modifier = Modifier.weight(1f),
        )
        RadioButton(
            selected = selected,
            onClick = onSelect,
            colors = RadioButtonDefaults.colors(
                selectedColor = colors.accent,
                unselectedColor = colors.tertiaryText,
            ),
        )
    }
}

@Composable
private fun DisplayModeRow(
    label: String,
    example: String,
    icon: ImageVector,
    selected: Boolean,
    accentColor: Color,
    onSelect: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onSelect)
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(if (selected) accentColor else accentColor.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (selected) Color.White else accentColor,
                modifier = Modifier.size(20.dp),
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(label, color = colors.primaryText, fontSize = DS.FontSize.Body.scaled(metrics), fontWeight = FontWeight.Medium)
            Text(example, color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
        }
        if (selected) {
            Icon(Icons.Default.CheckCircle, contentDescription = null, tint = accentColor, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun TitlePreviewRow(
    original: String,
    type: String,
    displayMode: TitleDisplayMode,
    subtitleHandling: SubtitleHandling,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val transformed = transformTitle(original, displayMode, subtitleHandling)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = type.uppercase(),
            color = colors.tertiaryText,
            fontSize = DS.FontSize.Caption.scaled(metrics),
            fontWeight = FontWeight.Bold,
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text("Original:", color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                Text(
                    text = original,
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                    textDecoration = if (transformed != original) TextDecoration.LineThrough else null,
                )
            }
            Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = null, tint = colors.tertiaryText, modifier = Modifier.size(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text("Display:", color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                Text(
                    text = transformed,
                    color = colors.accent,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                    fontWeight = FontWeight.Medium,
                )
            }
        }
    }
}

private fun transformTitle(original: String, mode: TitleDisplayMode, subtitleHandling: SubtitleHandling): String =
    LibraryDisplayTitleFormatter.displayTitle(original, mode, subtitleHandling)

private fun iconForBookCardStyle(style: BookCardStyle): ImageVector = when (style) {
    BookCardStyle.STANDARD -> Icons.AutoMirrored.Filled.LibraryBooks
    BookCardStyle.COMPACT -> Icons.Default.Title
    BookCardStyle.COVER_ONLY -> Icons.Default.Image
}

private fun iconForTitleMode(mode: TitleDisplayMode): ImageVector = when (mode) {
    TitleDisplayMode.PRESERVE -> Icons.Default.TextFields
    TitleDisplayMode.STRIP_PREFIX -> Icons.Default.FormatClear
    TitleDisplayMode.MOVE_TO_SUFFIX -> Icons.Default.TextRotationNone
    TitleDisplayMode.EXTRACT_TO_SERIES -> Icons.Default.AccountTree
}

private fun iconForAggressiveness(aggressiveness: MergeAggressiveness): ImageVector = when (aggressiveness) {
    MergeAggressiveness.CONSERVATIVE -> Icons.Default.Shield
    MergeAggressiveness.NORMAL -> Icons.Default.Balance
    MergeAggressiveness.AGGRESSIVE -> Icons.Default.Whatshot
}

private fun aggressivenessColor(aggressiveness: MergeAggressiveness): Color = when (aggressiveness) {
    MergeAggressiveness.CONSERVATIVE -> Color(0xFF6F8F6A)
    MergeAggressiveness.NORMAL -> Color(0xFF64748B)
    MergeAggressiveness.AGGRESSIVE -> Color(0xFFF5921A)
}
