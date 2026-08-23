package com.enve.app.ui.screens

import androidx.compose.animation.core.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.core.data.model.BookSource
import com.enve.hearth.design.hearthDisplay
import com.enve.core.data.model.Library
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsHeroHeader
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.LibraryViewModel
import kotlinx.coroutines.launch

private val HearthEmber = Color(0xFFF5921A)
private val HearthSage = Color(0xFF6F8F6A)
private val HearthSlate = Color(0xFF64748B)
private val HearthWine = Color(0xFFA05252)
private val HearthRed = Color(0xFFB3453E)

@Composable
fun LibraryManagementHubScreen(
    viewModel: LibraryViewModel,
    onBack: () -> Unit,
    onNavigateToConnections: () -> Unit,
) {
    val state by viewModel.state.collectAsState()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)
    val scope = rememberCoroutineScope()

    var connectionHealth by remember { mutableStateOf<Map<String, Boolean>>(emptyMap()) }
    var isCheckingHealth by remember { mutableStateOf(false) }
    var isScanning by remember { mutableStateOf(false) }
    var isRefreshingMetadata by remember { mutableStateOf(false) }
    var actionMessage by remember { mutableStateOf<String?>(null) }

    fun checkHealth() {
        scope.launch {
            isCheckingHealth = true
            connectionHealth = viewModel.checkAllConnectionsHealth()
            isCheckingHealth = false
        }
    }

    LaunchedEffect(Unit) { checkHealth() }

    Box(modifier = Modifier.fillMaxSize()) {
        SettingsScreenLayout(animatedBackground = true) {
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
                        text = "Library",
                        color = colors.primaryText,
                        style = hearthDisplay(22.sp),
                        modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                    )
                }

                SettingsHeroHeader(
                    title = "Library Management",
                    subtitle = "Manage connections, scan libraries, and perform bulk actions.",
                    modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
                )

                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Default.NetworkCheck, contentDescription = null, tint = colors.accent, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
                        Text(
                            text = "CONNECTION HEALTH",
                            color = colors.tertiaryText,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            letterSpacing = 1.6.sp,
                            modifier = Modifier.weight(1f),
                        )
                        if (isCheckingHealth) {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = colors.accent)
                        } else {
                            IconButton(onClick = { checkHealth() }, modifier = Modifier.size(32.dp)) {
                                Icon(Icons.Default.Refresh, contentDescription = "Refresh", tint = colors.accent, modifier = Modifier.size(16.dp))
                            }
                        }
                    }

                    HorizontalDivider(color = dividerColor, modifier = Modifier.padding(vertical = DS.Spacing.SM.scaled(metrics)))

                    val connections = state.connections
                    if (connections.isEmpty()) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Warning, contentDescription = null, tint = colors.accent, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
                            Text(
                                text = "No servers connected",
                                color = colors.secondaryText,
                                fontSize = DS.FontSize.Body.scaled(metrics),
                            )
                        }
                    } else {
                        val online = connections.count { connectionHealth[it.id] == true }
                        val offline = connections.count { connectionHealth[it.id] == false }
                        val unchecked = connections.count { !connectionHealth.containsKey(it.id) }

                        Row(
                            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
                            modifier = Modifier.padding(bottom = DS.Spacing.SM.scaled(metrics)),
                        ) {
                            HealthBadge(count = online, label = "Online", color = HearthSage)
                            if (offline > 0) HealthBadge(count = offline, label = "Offline", color = HearthRed)
                            if (unchecked > 0) HealthBadge(count = unchecked, label = "Checking", color = HearthSlate)
                        }

                        HorizontalDivider(color = dividerColor, modifier = Modifier.padding(bottom = DS.Spacing.SM.scaled(metrics)))

                        connections.forEach { conn ->
                            val health = connectionHealth[conn.id]
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                val dotColor = when {
                                    health == null -> HearthSlate
                                    health -> HearthSage
                                    else -> HearthRed
                                }
                                Box(
                                    modifier = Modifier
                                        .size(10.dp)
                                        .clip(CircleShape)
                                        .background(dotColor),
                                )
                                Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(conn.name, color = colors.primaryText, fontSize = DS.FontSize.Body.scaled(metrics), fontWeight = FontWeight.Medium)
                                    Text(conn.source.displayName, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                                }
                                Icon(
                                    imageVector = when {
                                        health == null -> Icons.AutoMirrored.Filled.HelpOutline
                                        health -> Icons.Default.CheckCircle
                                        else -> Icons.Default.Cancel
                                    },
                                    contentDescription = null,
                                    tint = dotColor,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        }
                    }
                }

                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.AutoMirrored.Filled.LibraryBooks, contentDescription = null, tint = HearthWine, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
                        Text(
                            text = "LIBRARY OVERVIEW",
                            color = colors.tertiaryText,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            letterSpacing = 1.6.sp,
                        )
                    }

                    HorizontalDivider(color = dividerColor, modifier = Modifier.padding(vertical = DS.Spacing.SM.scaled(metrics)))

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                    ) {
                        HubStatItem(value = state.libraries.size, label = "Libraries", color = HearthSlate)
                        HubStatItem(value = state.totalBookCount, label = "Books", color = HearthSage)
                        HubStatItem(value = state.connections.size, label = "Connections", color = HearthEmber)
                    }
                }

                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Bolt, contentDescription = null, tint = colors.accent, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
                        Text(
                            text = "QUICK ACTIONS",
                            color = colors.tertiaryText,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            letterSpacing = 1.6.sp,
                        )
                    }

                    HorizontalDivider(color = dividerColor, modifier = Modifier.padding(vertical = DS.Spacing.SM.scaled(metrics)))

                    val cols = 2
                    val actions = listOf(
                        Triple("Scan All", Icons.Default.Refresh, HearthEmber),
                        Triple("Refresh Metadata", Icons.Default.SyncAlt, HearthWine),
                        Triple("Check Health", Icons.Default.FavoriteBorder, HearthSage),
                        Triple("Library Connections", Icons.Default.Dns, HearthSlate),
                    )

                    val rows = (actions.size + cols - 1) / cols
                    Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
                        repeat(rows) { rowIdx ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                            ) {
                                repeat(cols) { colIdx ->
                                    val idx = rowIdx * cols + colIdx
                                    if (idx < actions.size) {
                                        val (label, icon, tint) = actions[idx]
                                        val busy = isScanning && label == "Scan All" ||
                                            isCheckingHealth && label == "Check Health" ||
                                            isRefreshingMetadata && label == "Refresh Metadata"
                                        HubActionButton(
                                            label = label,
                                            icon = icon,
                                            tint = tint,
                                            busy = busy,
                                            modifier = Modifier.weight(1f),
                                            onClick = {
                                                when (label) {
                                                    "Scan All" -> scope.launch {
                                                        isScanning = true
                                                        actionMessage = null
                                                        viewModel.refresh()
                                                        isScanning = false
                                                        actionMessage = "Library scan started"
                                                    }
                                                    "Refresh Metadata" -> scope.launch {
                                                        isRefreshingMetadata = true
                                                        actionMessage = null
                                                        val processed = runCatching { viewModel.refreshCachedMetadata() }
                                                            .getOrElse { 0 }
                                                        isRefreshingMetadata = false
                                                        actionMessage = if (processed == 1) {
                                                            "Refreshed metadata for 1 audiobook"
                                                        } else {
                                                            "Refreshed metadata for $processed audiobooks"
                                                        }
                                                    }
                                                    "Check Health" -> checkHealth()
                                                    "Library Connections" -> onNavigateToConnections()
                                                }
                                            },
                                        )
                                    } else {
                                        Spacer(Modifier.weight(1f))
                                    }
                                }
                            }
                        }
                    }
                }

                actionMessage?.let { message ->
                    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                text = message,
                                color = colors.secondaryText,
                                fontSize = DS.FontSize.Body.scaled(metrics),
                                modifier = Modifier.weight(1f),
                            )
                            TextButton(onClick = { actionMessage = null }) {
                                Text("Dismiss")
                            }
                        }
                    }
                }

                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Default.Folder, contentDescription = null, tint = HearthSage, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
                        Text(
                            text = "LIBRARIES",
                            color = colors.tertiaryText,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            letterSpacing = 1.6.sp,
                            modifier = Modifier.weight(1f),
                        )
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(DS.Radius.Pill))
                                .background(colors.cardBackground)
                                .padding(horizontal = DS.Spacing.SM.scaled(metrics), vertical = 2.dp),
                        ) {
                            Text(
                                text = "${state.libraries.size}",
                                color = colors.secondaryText,
                                fontSize = DS.FontSize.Caption.scaled(metrics),
                            )
                        }
                    }

                    HorizontalDivider(color = dividerColor, modifier = Modifier.padding(vertical = DS.Spacing.SM.scaled(metrics)))

                    if (state.libraries.isEmpty()) {
                        Text(
                            text = "No libraries found",
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Body.scaled(metrics),
                            modifier = Modifier.padding(vertical = DS.Spacing.MD.scaled(metrics)),
                        )
                    } else {
                        state.libraries.forEachIndexed { index, library ->
                            LibraryRow(
                                library = library,
                                excluded = state.excludedLibraryIds.contains(library.id),
                                onToggleExclusion = { viewModel.toggleLibraryExclusion(library.id) },
                            )
                            if (index < state.libraries.lastIndex) {
                                HorizontalDivider(color = dividerColor)
                            }
                        }
                    }
                }

                Spacer(Modifier.height(80.dp.scaled(metrics)))
            }
        }

        if (isScanning) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.4f)),
                contentAlignment = Alignment.Center,
            ) {
                Card(
                    shape = RoundedCornerShape(if (EnveTheme.eink.sharpCorners) 4.dp else DS.Radius.Large),
                    colors = CardDefaults.cardColors(containerColor = colors.cardBackground),
                ) {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.XL.scaled(metrics)),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                    ) {
                        CircularProgressIndicator(color = colors.accent)
                        Text(
                            "Scanning...",
                            color = colors.primaryText,
                            fontSize = DS.FontSize.Body.scaled(metrics),
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun HealthBadge(count: Int, label: String, color: Color) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(color))
        Text("$count $label", color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
    }
}

@Composable
private fun HubStatItem(value: Int, label: String, color: Color) {
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
            color = color,
            fontSize = DS.FontSize.Title2.scaled(metrics),
            fontWeight = FontWeight.Bold,
        )
        Text(label, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
    }
}

@Composable
private fun HubActionButton(
    label: String,
    icon: ImageVector,
    tint: Color,
    busy: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val metrics = rememberAdaptiveMetrics()
    Button(
        onClick = onClick,
        enabled = !busy,
        modifier = modifier.height(72.dp),
        shape = RoundedCornerShape(DS.Radius.Standard),
        border = BorderStroke(1.dp, if (busy) tint.copy(alpha = 0.4f) else tint),
        colors = ButtonDefaults.buttonColors(
            containerColor = Color.Transparent,
            contentColor = tint,
            disabledContainerColor = Color.Transparent,
            disabledContentColor = tint.copy(alpha = 0.4f),
        ),
        contentPadding = PaddingValues(horizontal = DS.Spacing.MD.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            if (busy) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = tint)
            } else {
                Icon(imageVector = icon, contentDescription = null, modifier = Modifier.size(22.dp))
            }
            Spacer(Modifier.height(4.dp))
            Text(label, fontSize = DS.FontSize.Caption.scaled(metrics), fontWeight = FontWeight.Medium)
        }
    }
}

@Composable
private fun LibraryRow(
    library: Library,
    excluded: Boolean,
    onToggleExclusion: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = DS.Spacing.SM.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = iconForSource(library.source),
            contentDescription = null,
            tint = if (excluded) colors.tertiaryText else colors.accent,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = library.name,
                color = if (excluded) colors.secondaryText else colors.primaryText,
                fontSize = DS.FontSize.Body.scaled(metrics),
                fontWeight = FontWeight.Medium,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
                Text(library.source.displayName, color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                Text(
                    text = if (excluded) "Hidden" else "Visible",
                    color = if (excluded) colors.tertiaryText else HearthSage,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
        }
        IconButton(onClick = onToggleExclusion, modifier = Modifier.size(32.dp)) {
            Icon(
                imageVector = if (excluded) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                contentDescription = if (excluded) "Show" else "Hide",
                tint = if (excluded) colors.tertiaryText else colors.accent,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

private fun iconForSource(source: BookSource): ImageVector = when (source) {
    BookSource.PLEX -> Icons.Default.Tv
    BookSource.AUDIOBOOKSHELF -> Icons.AutoMirrored.Filled.LibraryBooks
    BookSource.JELLYFIN, BookSource.EMBY -> Icons.Default.PlayCircle
    BookSource.GRIMMORY -> Icons.Default.AutoStories
    BookSource.KOMGA, BookSource.KAVITA, BookSource.BOOKORBIT, BookSource.SILO -> Icons.AutoMirrored.Filled.MenuBook
    BookSource.OPDS -> Icons.Default.RssFeed
    BookSource.WEBDAV, BookSource.TORBOX, BookSource.PREMIUMIZE, BookSource.REALDEBRID -> Icons.Default.Storage
    BookSource.SMB -> Icons.Default.Dns
    BookSource.LOCAL -> Icons.Default.Folder
    BookSource.STORYTELLER -> Icons.Default.RecordVoiceOver
}
