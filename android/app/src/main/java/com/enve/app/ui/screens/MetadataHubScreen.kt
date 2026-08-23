package com.enve.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.hearth.design.hearthDisplay
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsHeroHeader
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.SettingsSectionHeader
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.MetadataHubState
import com.enve.app.viewmodel.MetadataHubViewModel

private val HearthSage = Color(0xFF6F8F6A)
private val HearthWine = Color(0xFFA05252)
private val HearthRed = Color(0xFFB3453E)

@Composable
fun MetadataHubScreen(
    onBack: () -> Unit,
) {
    val viewModel: MetadataHubViewModel = hiltViewModel()
    val state by viewModel.state.collectAsState()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)

    SettingsScreenLayout(animatedBackground = EnveTheme.dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .statusBarsPadding()
                .padding(bottom = DS.Spacing.XXL.scaled(metrics)),
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
                    text = "Metadata",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
                Spacer(Modifier.weight(1f))
                TextButton(onClick = viewModel::refreshSnapshot) {
                    Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Refresh")
                }
            }

            SettingsHeroHeader(
                title = "Metadata Hub",
                subtitle = "Refresh local metadata and run single-book matching for audiobooks and ebooks.",
                icon = Icons.Default.AutoAwesome,
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )

            MetadataSummaryCard(state)

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(title = "Actions")
                MetadataActionRow(
                    icon = Icons.Default.CloudSync,
                    tint = HearthSage,
                    title = "Refresh Library Metadata",
                    subtitle = "Re-indexes all enabled sources into the local metadata cache.",
                    isRunning = state.isRefreshingCache,
                    buttonText = "Refresh",
                    onClick = viewModel::refreshLibraryCache,
                )
                HorizontalDivider(color = dividerColor)
                MetadataActionRow(
                    icon = Icons.Default.RecordVoiceOver,
                    tint = HearthWine,
                    title = "Enrich Audiobook Narrators",
                    subtitle = if (state.pendingNarratorEnrichment > 0) {
                        "${state.pendingNarratorEnrichment} audiobook${if (state.pendingNarratorEnrichment == 1) "" else "s"} need narrator lookup."
                    } else {
                        "All cached audiobook narrator rows have been checked."
                    },
                    isRunning = state.isEnrichingNarrators,
                    buttonText = "Run",
                    enabled = state.pendingNarratorEnrichment > 0,
                    onClick = viewModel::enrichNarrators,
                )
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(title = "Providers")
                if (state.activeSources.isEmpty()) {
                    EmptyMetadataText("No enabled metadata sources are connected.")
                } else {
                    state.activeSources.forEachIndexed { index, source ->
                        MetadataProviderRow(source.displayName)
                        if (index < state.activeSources.lastIndex) HorizontalDivider(color = dividerColor)
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(title = "Matching")
                MetadataInfoRow(
                    icon = Icons.Default.AutoAwesome,
                    tint = HearthSage,
                    title = "Single Book Matching",
                    subtitle = "Book detail screens can search and apply Enve metadata matches for audiobooks and ebooks.",
                )
            }

            state.error?.let {
                val mono = EnveTheme.eink.monochrome
                MetadataMessageCard(
                    text = if (mono) "⚠ $it" else it,
                    tint = if (mono) colors.primaryText else HearthRed,
                    onDismiss = viewModel::clearTransientMessage,
                )
            }
            state.message?.let {
                MetadataMessageCard(text = it, tint = colors.accent, onDismiss = viewModel::clearTransientMessage)
            }

            Spacer(Modifier.height(80.dp.scaled(metrics)))
        }
    }
}

@Composable
private fun MetadataSummaryCard(state: MetadataHubState) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DS.Spacing.LG.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                MetadataIcon(Icons.Default.Storage, HearthSage)
                Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        "Metadata Cache",
                        color = colors.primaryText,
                        fontSize = DS.FontSize.Headline.scaled(metrics),
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        "Local index used by Library, Browse, Home, and detail screens.",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
                if (state.isRefreshingCache) {
                    CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp, color = colors.accent)
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
            ) {
                MetadataMetric("Books", state.totalBooks.toString(), Modifier.weight(1f))
                MetadataMetric("Libraries", state.totalLibraries.toString(), Modifier.weight(1f))
                MetadataMetric("Sources", "${state.enabledConnections}/${state.totalConnections}", Modifier.weight(1f))
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                val healthy = state.pendingNarratorEnrichment == 0
                Icon(
                    imageVector = if (healthy) Icons.Default.CheckCircle else Icons.Default.Warning,
                    contentDescription = null,
                    tint = if (healthy) HearthSage else colors.accent,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
                Text(
                    text = if (healthy) "Narrator enrichment is current" else "${state.pendingNarratorEnrichment} narrator lookup${if (state.pendingNarratorEnrichment == 1) "" else "s"} pending",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun MetadataMetric(label: String, value: String, modifier: Modifier = Modifier) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val shape = RoundedCornerShape(if (EnveTheme.eink.sharpCorners) 4.dp else DS.Radius.Standard)
    Column(
        modifier = modifier
            .clip(shape)
            .background(colors.cardBackground)
            .border(
                width = if (EnveTheme.eink.active) 1.dp else 0.dp,
                color = colors.separator,
                shape = shape,
            )
            .padding(DS.Spacing.MD.scaled(metrics)),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(value, color = colors.primaryText, fontSize = DS.FontSize.Title3.scaled(metrics), fontWeight = FontWeight.Bold)
        Text(label, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
    }
}

@Composable
private fun MetadataActionRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
    isRunning: Boolean,
    buttonText: String,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MetadataIcon(icon, tint)
        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = colors.primaryText, fontSize = DS.FontSize.Body.scaled(metrics), fontWeight = FontWeight.SemiBold)
            Text(subtitle, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics), maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
        Button(
            onClick = onClick,
            enabled = enabled && !isRunning,
            shape = RoundedCornerShape(999.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = colors.accent,
                contentColor = Color.White,
            ),
        ) {
            if (isRunning) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = Color.White)
            } else {
                Text(buttonText)
            }
        }
    }
}

@Composable
private fun MetadataProviderRow(name: String) {
    MetadataInfoRow(
        icon = Icons.AutoMirrored.Filled.LibraryBooks,
        tint = HearthSage,
        title = name,
        subtitle = "Enabled source participating in metadata refresh.",
    )
}

@Composable
private fun MetadataInfoRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MetadataIcon(icon, tint)
        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = colors.primaryText, fontSize = DS.FontSize.Body.scaled(metrics), fontWeight = FontWeight.SemiBold)
            Text(subtitle, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics), maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun MetadataIcon(icon: ImageVector, tint: Color) {
    val colors = EnveTheme.colors
    val shape = RoundedCornerShape(if (EnveTheme.eink.sharpCorners) 4.dp else 12.dp)
    Box(
        modifier = Modifier
            .size(48.dp)
            .clip(shape)
            .then(
                if (EnveTheme.eink.suppressGradients) {
                    Modifier.border(1.dp, colors.primaryText, shape)
                } else {
                    Modifier.background(tint.copy(alpha = 0.14f))
                }
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = if (EnveTheme.eink.monochrome) colors.primaryText else tint)
    }
}

@Composable
private fun EmptyMetadataText(text: String) {
    val metrics = rememberAdaptiveMetrics()
    Text(
        text = text,
        color = EnveTheme.colors.secondaryText,
        fontSize = DS.FontSize.Caption.scaled(metrics),
        modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
    )
}

@Composable
private fun MetadataMessageCard(text: String, tint: Color, onDismiss: () -> Unit) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DS.Spacing.LG.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text, color = tint, fontSize = DS.FontSize.Body.scaled(metrics), modifier = Modifier.weight(1f))
            TextButton(onClick = onDismiss) { Text("Dismiss", color = colors.accent, fontSize = DS.FontSize.Caption.scaled(metrics)) }
        }
    }
}
