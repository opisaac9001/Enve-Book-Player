package com.enve.app.ui.screens

import androidx.compose.animation.core.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.core.data.model.BookSource
import com.enve.hearth.design.hearthDisplay
import com.enve.core.data.model.ProviderConnection
import com.enve.engine.servertools.ServerFeature
import com.enve.app.ui.components.BookSourceIcon
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsHeroHeader
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.SettingsSectionHeader
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.ServerManagementViewModel

private val HearthEmber = Color(0xFFF5921A)
private val HearthSage = Color(0xFF6F8F6A)
private val HearthSlate = Color(0xFF64748B)
private val HearthRed = Color(0xFFB3453E)

@Composable
fun ServerManagementHubScreen(
    onBack: () -> Unit,
    onNavigateToConnections: () -> Unit,
    onOpenServerTools: (String) -> Unit,
    viewModel: ServerManagementViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsState()
    val colors = EnveTheme.colors
    val eink = EnveTheme.eink
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)
    var pendingRemoval by remember { mutableStateOf<ProviderConnection?>(null) }

    LaunchedEffect(Unit) {
        viewModel.refreshHealth()
    }

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

                Text(
                    text = "Server Hub",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
            }

            SettingsHeroHeader(
                title = "Server Hub",
                subtitle = "Health, administration, and the reader features each server offers",
                icon = Icons.Default.Dns,
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(title = "Connected Servers")
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                ) {
                    AnimatedStatPill(value = state.activeConnections.size, label = "Servers")
                    AnimatedStatPill(value = state.platformCount, label = "Platforms")
                    AnimatedStatPill(
                        value = state.connectionHealth.values.count { it },
                        label = "Online",
                    )
                }
                if (state.pausedConnections.isNotEmpty()) {
                    HorizontalDivider(color = dividerColor, modifier = Modifier.padding(vertical = DS.Spacing.SM.scaled(metrics)))
                    Text(
                        text = "${state.pausedConnections.size} paused connection(s)",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                        modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
                    )
                }
            }

            serverGroup(
                title = "Audiobookshelf",
                subtitle = "${state.forSource(BookSource.AUDIOBOOKSHELF).size} server(s)",
                source = BookSource.AUDIOBOOKSHELF,
                icon = Icons.Default.Headphones,
                iconTint = HearthSage,
                state = state,
                dividerColor = dividerColor,
                onRefreshConnection = viewModel::refreshConnection,
                onSetConnectionEnabled = viewModel::setConnectionEnabled,
                onRemoveConnection = { pendingRemoval = it },
                onOpenTools = onOpenServerTools,
            )
            serverGroup(
                title = "Plex",
                subtitle = "${state.forSource(BookSource.PLEX).size} server(s)",
                source = BookSource.PLEX,
                icon = Icons.Default.PlayCircle,
                iconTint = HearthEmber,
                state = state,
                dividerColor = dividerColor,
                onRefreshConnection = viewModel::refreshConnection,
                onSetConnectionEnabled = viewModel::setConnectionEnabled,
                onRemoveConnection = { pendingRemoval = it },
                onOpenTools = onOpenServerTools,
            )
            serverGroup(
                title = "Jellyfin / Emby",
                subtitle = "${state.forSource(BookSource.JELLYFIN).size + state.forSource(BookSource.EMBY).size} server(s)",
                source = BookSource.JELLYFIN,
                icon = Icons.Default.Storage,
                iconTint = HearthSlate,
                state = state,
                dividerColor = dividerColor,
                onRefreshConnection = viewModel::refreshConnection,
                onSetConnectionEnabled = viewModel::setConnectionEnabled,
                onRemoveConnection = { pendingRemoval = it },
                onOpenTools = onOpenServerTools,
                extraSources = listOf(BookSource.EMBY),
            )
            brandedServerGroup(
                title = "Grimmory",
                subtitle = "${state.forSource(BookSource.GRIMMORY).size} server(s)",
                source = BookSource.GRIMMORY,
                iconTint = colors.accent,
                state = state,
                dividerColor = dividerColor,
                onRefreshConnection = viewModel::refreshConnection,
                onSetConnectionEnabled = viewModel::setConnectionEnabled,
                onRemoveConnection = { pendingRemoval = it },
                onOpenTools = onOpenServerTools,
            )
            brandedServerGroup(
                title = "Storyteller",
                subtitle = "${state.forSource(BookSource.STORYTELLER).size} server(s)",
                source = BookSource.STORYTELLER,
                iconTint = HearthSage,
                state = state,
                dividerColor = dividerColor,
                onRefreshConnection = viewModel::refreshConnection,
                onSetConnectionEnabled = viewModel::setConnectionEnabled,
                onRemoveConnection = { pendingRemoval = it },
                onOpenTools = onOpenServerTools,
            )
            serverGroup(
                title = "WebDAV / Cloud",
                subtitle = "${state.forSource(BookSource.WEBDAV).size} connection(s)",
                source = BookSource.WEBDAV,
                icon = Icons.Default.Cloud,
                iconTint = HearthSlate,
                state = state,
                dividerColor = dividerColor,
                onRefreshConnection = viewModel::refreshConnection,
                onSetConnectionEnabled = viewModel::setConnectionEnabled,
                onRemoveConnection = { pendingRemoval = it },
                onOpenTools = onOpenServerTools,
            )
            serverGroup(
                title = "Komga",
                subtitle = "${state.forSource(BookSource.KOMGA).size} server(s)",
                source = BookSource.KOMGA,
                icon = Icons.Default.AutoStories,
                iconTint = HearthSage,
                state = state,
                dividerColor = dividerColor,
                onRefreshConnection = viewModel::refreshConnection,
                onSetConnectionEnabled = viewModel::setConnectionEnabled,
                onRemoveConnection = { pendingRemoval = it },
                onOpenTools = onOpenServerTools,
            )
            serverGroup(
                title = "Kavita",
                subtitle = "${state.forSource(BookSource.KAVITA).size} server(s)",
                source = BookSource.KAVITA,
                icon = Icons.Default.AutoStories,
                iconTint = HearthSage,
                state = state,
                dividerColor = dividerColor,
                onRefreshConnection = viewModel::refreshConnection,
                onSetConnectionEnabled = viewModel::setConnectionEnabled,
                onRemoveConnection = { pendingRemoval = it },
                onOpenTools = onOpenServerTools,
            )
            serverGroup(
                title = "BookOrbit",
                subtitle = "${state.forSource(BookSource.BOOKORBIT).size} server(s)",
                source = BookSource.BOOKORBIT,
                icon = Icons.Default.Language,
                iconTint = HearthSlate,
                state = state,
                dividerColor = dividerColor,
                onRefreshConnection = viewModel::refreshConnection,
                onSetConnectionEnabled = viewModel::setConnectionEnabled,
                onRemoveConnection = { pendingRemoval = it },
                onOpenTools = onOpenServerTools,
            )
            serverGroup(
                title = "Silo",
                subtitle = "${state.forSource(BookSource.SILO).size} server(s)",
                source = BookSource.SILO,
                icon = Icons.AutoMirrored.Filled.MenuBook,
                iconTint = HearthSage,
                state = state,
                dividerColor = dividerColor,
                onRefreshConnection = viewModel::refreshConnection,
                onSetConnectionEnabled = viewModel::setConnectionEnabled,
                onRemoveConnection = { pendingRemoval = it },
                onOpenTools = onOpenServerTools,
            )
            serverGroup(
                title = "OPDS",
                subtitle = "${state.forSource(BookSource.OPDS).size} feed(s)",
                source = BookSource.OPDS,
                icon = Icons.Default.Language,
                iconTint = HearthEmber,
                state = state,
                dividerColor = dividerColor,
                onRefreshConnection = viewModel::refreshConnection,
                onSetConnectionEnabled = viewModel::setConnectionEnabled,
                onRemoveConnection = { pendingRemoval = it },
                onOpenTools = onOpenServerTools,
            )

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(title = "Quick Actions")
                ServerActionRow(
                    icon = Icons.Default.Dns,
                    iconTint = colors.accent,
                    title = "Add Server",
                    subtitle = "Open library connections",
                    onClick = onNavigateToConnections,
                )
                HorizontalDivider(color = dividerColor)
                ServerActionRow(
                    icon = Icons.Default.CheckCircle,
                    iconTint = HearthSage,
                    title = if (state.isCheckingHealth) "Checking Health" else "Check Health",
                    subtitle = "Run diagnostics across enabled services",
                    busy = state.isCheckingHealth,
                    onClick = viewModel::refreshHealth,
                )
            }

            state.message?.let { message ->
                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(DS.Spacing.LG.scaled(metrics)),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = message,
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Body.scaled(metrics),
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = viewModel::clearMessage) {
                            Text("Dismiss")
                        }
                    }
                }
            }

            Spacer(Modifier.height(80.dp.scaled(metrics)))
        }
    }

    pendingRemoval?.let { connection ->
        AlertDialog(
            onDismissRequest = { pendingRemoval = null },
            title = { Text("Remove ${connection.name}?") },
            text = { Text("This removes the connection and clears its cached library entries. Downloaded files remain on this device.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingRemoval = null
                        viewModel.removeConnection(connection.id)
                    },
                ) {
                    Text("Remove", color = if (eink.monochrome) colors.primaryText else HearthRed)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingRemoval = null }) {
                    Text("Cancel")
                }
            },
        )
    }
}

@Composable
private fun serverGroup(
    title: String,
    subtitle: String,
    source: BookSource,
    icon: ImageVector,
    iconTint: Color,
    state: com.enve.app.viewmodel.ServerManagementState,
    dividerColor: Color,
    onRefreshConnection: (String) -> Unit,
    onSetConnectionEnabled: (String, Boolean) -> Unit,
    onRemoveConnection: (ProviderConnection) -> Unit,
    onOpenTools: (String) -> Unit,
    extraSources: List<BookSource> = emptyList(),
) {
    val metrics = rememberAdaptiveMetrics()
    val connections = (listOf(source) + extraSources).flatMap { state.forSource(it) }
    if (connections.isEmpty()) return

    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = title, subtitle = subtitle)
        connections.forEachIndexed { index, connection ->
            ConnectionManagementRow(
                icon = icon,
                iconTint = iconTint,
                connection = connection,
                health = state.connectionHealth[connection.id],
                features = state.connectionFeatures[connection.id].orEmpty(),
                busy = connection.id in state.busyConnectionIds,
                onRefresh = { onRefreshConnection(connection.id) },
                onSetEnabled = { enabled -> onSetConnectionEnabled(connection.id, enabled) },
                onRemove = { onRemoveConnection(connection) },
                onOpenTools = { onOpenTools(connection.id) },
            )
            if (index < connections.lastIndex) {
                HorizontalDivider(color = dividerColor)
            }
        }
    }
}

@Composable
private fun brandedServerGroup(
    title: String,
    subtitle: String,
    source: BookSource,
    iconTint: Color,
    state: com.enve.app.viewmodel.ServerManagementState,
    dividerColor: Color,
    onRefreshConnection: (String) -> Unit,
    onSetConnectionEnabled: (String, Boolean) -> Unit,
    onRemoveConnection: (ProviderConnection) -> Unit,
    onOpenTools: (String) -> Unit,
) {
    val metrics = rememberAdaptiveMetrics()
    val brandTint = if (EnveTheme.eink.monochrome) EnveTheme.colors.primaryText else iconTint
    val connections = state.forSource(source)
    if (connections.isEmpty()) return

    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = title, subtitle = subtitle)
        connections.forEachIndexed { index, connection ->
            ConnectionManagementRow(
                iconTint = iconTint,
                connection = connection,
                health = state.connectionHealth[connection.id],
                features = state.connectionFeatures[connection.id].orEmpty(),
                busy = connection.id in state.busyConnectionIds,
                onRefresh = { onRefreshConnection(connection.id) },
                onSetEnabled = { enabled -> onSetConnectionEnabled(connection.id, enabled) },
                onRemove = { onRemoveConnection(connection) },
                onOpenTools = { onOpenTools(connection.id) },
                iconContent = {
                    BookSourceIcon(
                        source = source,
                        tint = brandTint,
                        modifier = Modifier.size(DS.IconSize.Large.scaled(metrics)),
                    )
                },
            )
            if (index < connections.lastIndex) {
                HorizontalDivider(color = dividerColor)
            }
        }
    }
}

@Composable
private fun ConnectionManagementRow(
    iconTint: Color,
    connection: ProviderConnection,
    health: Boolean?,
    features: Set<ServerFeature>,
    busy: Boolean,
    onRefresh: () -> Unit,
    onSetEnabled: (Boolean) -> Unit,
    onRemove: () -> Unit,
    onOpenTools: () -> Unit,
    icon: ImageVector? = null,
    iconContent: (@Composable () -> Unit)? = null,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink
    val statusColor = when {
        !connection.enabled -> colors.tertiaryText
        health == true -> HearthSage
        health == false -> HearthRed
        else -> HearthSlate
    }
    val statusLabel = when {
        !connection.enabled -> "Paused"
        health == true -> "Online"
        health == false -> "Offline"
        else -> "Unchecked"
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = DS.Spacing.MD.scaled(metrics)),
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onOpenTools),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp.scaled(metrics))
                    .clip(CircleShape)
                    .then(
                        if (eink.monochrome) Modifier.border(1.dp, colors.primaryText, CircleShape)
                        else Modifier.background(iconTint.copy(alpha = 0.16f))
                    ),
                contentAlignment = Alignment.Center,
            ) {
                if (iconContent != null) {
                    iconContent()
                } else if (icon != null) {
                    Icon(
                        icon,
                        contentDescription = null,
                        tint = if (eink.monochrome) colors.primaryText else iconTint,
                        modifier = Modifier.size(22.dp.scaled(metrics)),
                    )
                }
            }
            Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = connection.name,
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Body.scaled(metrics),
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = connection.serverUrl,
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                    maxLines = 1,
                )
            }
            if (eink.monochrome) {

                val pillShape = RoundedCornerShape(4.dp)
                val checked = connection.enabled && health != null
                Row(
                    modifier = Modifier
                        .clip(pillShape)
                        .background(colors.secondaryBackground)
                        .border(1.dp, colors.primaryText, pillShape)
                        .padding(horizontal = DS.Spacing.SM.scaled(metrics), vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .then(
                                if (checked) Modifier.background(colors.primaryText, CircleShape)
                                else Modifier.border(1.dp, colors.primaryText, CircleShape)
                            ),
                    )
                    Text(
                        text = if (health == false && connection.enabled) "! $statusLabel" else statusLabel,
                        color = colors.primaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            } else {
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(DS.Radius.Pill))
                        .background(statusColor.copy(alpha = 0.14f))
                        .padding(horizontal = DS.Spacing.SM.scaled(metrics), vertical = 4.dp),
                ) {
                    Text(
                        text = statusLabel,
                        color = statusColor,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            Icon(
                Icons.Default.ChevronRight,
                contentDescription = "Open ${connection.name} tools",
                tint = colors.tertiaryText,
                modifier = Modifier
                    .padding(start = DS.Spacing.SM.scaled(metrics))
                    .size(20.dp.scaled(metrics)),
            )
        }

        if (features.isNotEmpty()) {
            FeatureChips(features)
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
        ) {
            OutlinedButton(
                onClick = { onSetEnabled(!connection.enabled) },
                enabled = !busy,
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(999.dp),
                border = BorderStroke(1.dp, if (eink.monochrome) colors.primaryText else colors.accent),
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = if (eink.monochrome) colors.primaryText else colors.accent,
                ),
            ) {
                Icon(
                    imageVector = if (connection.enabled) Icons.Default.PauseCircle else Icons.Default.PlayCircle,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(4.dp))
                Text(if (connection.enabled) "Pause" else "Resume")
            }
            OutlinedButton(
                onClick = onRefresh,
                enabled = !busy && connection.enabled,
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(999.dp),
                border = BorderStroke(1.dp, if (eink.monochrome) colors.primaryText else colors.accent),
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = if (eink.monochrome) colors.primaryText else colors.accent,
                ),
            ) {
                if (busy) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
                }
                Spacer(Modifier.width(4.dp))
                Text("Refresh")
            }
            OutlinedButton(
                onClick = onRemove,
                enabled = !busy,
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(999.dp),
                border = BorderStroke(1.dp, if (eink.monochrome) colors.primaryText else HearthRed),
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = if (eink.monochrome) colors.primaryText else HearthRed,
                ),
            ) {
                Icon(Icons.Default.Delete, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text("Remove")
            }
        }
    }
}

@Composable
private fun FeatureChips(features: Set<ServerFeature>) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink
    val shape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(DS.Radius.Pill)
    Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.XS.scaled(metrics))) {
        ServerFeature.entries.filter { it in features }.forEach { feature ->
            Box(
                modifier = Modifier
                    .clip(shape)
                    .then(
                        if (eink.monochrome) Modifier.border(1.dp, colors.primaryText, shape)
                        else Modifier.background(colors.accent.copy(alpha = 0.12f))
                    )
                    .padding(horizontal = DS.Spacing.SM.scaled(metrics), vertical = 3.dp),
            ) {
                Text(
                    text = featureLabel(feature),
                    color = if (eink.monochrome) colors.primaryText else colors.accent,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                    fontWeight = FontWeight.Medium,
                )
            }
        }
    }
}

private fun featureLabel(feature: ServerFeature): String = when (feature) {
    ServerFeature.STATS -> "Insights"
    ServerFeature.ACHIEVEMENTS -> "Achievements"
    ServerFeature.HIGHLIGHTS -> "Highlights"
    ServerFeature.BOOKMARKS -> "Bookmarks"
    ServerFeature.HISTORY -> "History"
    ServerFeature.RECOMMENDATIONS -> "Recommendations"
}

@Composable
private fun ServerActionRow(
    icon: ImageVector,
    iconTint: Color,
    title: String,
    subtitle: String,
    busy: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink
    val tint = if (eink.monochrome) colors.primaryText else iconTint
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = !busy, onClick = onClick)
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(44.dp.scaled(metrics))
                .clip(CircleShape)
                .then(
                    if (eink.monochrome) Modifier.border(1.dp, colors.primaryText, CircleShape)
                    else Modifier.background(iconTint.copy(alpha = 0.16f))
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (busy) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = tint)
            } else {
                Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp.scaled(metrics)))
            }
        }
        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = colors.primaryText, fontSize = DS.FontSize.Body.scaled(metrics), fontWeight = FontWeight.SemiBold)
            Text(subtitle, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
        }
        IconButton(onClick = onClick, enabled = !busy) {
            Icon(Icons.Default.ChevronRight, contentDescription = title, tint = colors.tertiaryText)
        }
    }
}

@Composable
private fun AnimatedStatPill(value: Int, label: String) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    val animatedValue by animateIntAsState(
        targetValue = value,
        animationSpec = tween(600, easing = FastOutSlowInEasing),
        label = "stat_$label",
    )

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = animatedValue.toString(),
            color = colors.primaryText,
            fontSize = DS.FontSize.Title2.scaled(metrics),
            fontWeight = FontWeight.Black,
        )
        Text(
            text = label,
            color = colors.secondaryText,
            fontSize = DS.FontSize.Caption.scaled(metrics),
            fontWeight = FontWeight.Medium,
        )
    }
}
