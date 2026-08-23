package com.enve.app.ui.screens

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Router
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.R
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.app.ui.components.BookSourceIcon
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.openInAppBrowser
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.ui.auth.AuthState
import com.enve.app.ui.auth.AuthViewModel

private data class ConnectionOption(
    val source: BookSource,
    val title: String,
    val iconRes: Int? = null,
    val iconVector: ImageVector? = null,
    val tint: Color,
    val supported: Boolean = false,
)

@Composable
fun LibraryConnectionsScreen(
    authState: AuthState,
    authViewModel: AuthViewModel,
    onBack: () -> Unit = {},
    onNavigateToServiceLogin: (BookSource, String?) -> Unit = { _, _ -> },
    onSourceChange: (BookSource) -> Unit = {},
    onServerUrlChange: (String) -> Unit = {},
    onUsernameChange: (String) -> Unit = {},
    onPasswordChange: (String) -> Unit = {},
    onLogin: () -> Unit = {},
    onLoginWithToken: (String) -> Unit = {},
    onStartOidcLogin: () -> Unit = {},
    onConsumeBrowserAuthUrl: () -> Unit = {},
    onLogout: () -> Unit = {},
    onNavigateToKomgaHub: () -> Unit = {},
    onNavigateToSiloHub: () -> Unit = {},
    onNavigateToServerManagement: () -> Unit = {},
) {
    val colors = EnveTheme.colors
    val eink = EnveTheme.eink
    val context = LocalContext.current
    val connections by authViewModel.listConnections().collectAsState(initial = emptyList())
    var showPlexHomeUserSheet by remember { mutableStateOf(false) }
    val metrics = rememberAdaptiveMetrics()

    LaunchedEffect(authState.browserAuthUrl) {
        val url = authState.browserAuthUrl
        if (!url.isNullOrBlank()) {
            openInAppBrowser(context, url, colors.accent)
            onConsumeBrowserAuthUrl()
        }
    }

    val mediaServerOptions = listOf(
        ConnectionOption(BookSource.AUDIOBOOKSHELF, "Audiobookshelf", iconRes = R.drawable.ic_audiobookshelf, tint = Color(0xFFC8A45A), supported = true),
        ConnectionOption(BookSource.PLEX, "Plex", iconRes = R.drawable.ic_plex, tint = Color(0xFFE5A319), supported = true),
        ConnectionOption(BookSource.JELLYFIN, "Jellyfin", iconRes = R.drawable.ic_jellyfin, tint = Color(0xFF9C6BDB), supported = true),
        ConnectionOption(BookSource.EMBY, "Emby", iconRes = R.drawable.ic_emby, tint = Color(0xFF4CAF7D), supported = true),
        ConnectionOption(BookSource.GRIMMORY, "Grimmory", iconRes = R.drawable.ic_grimmory, tint = colors.accent, supported = true),
        ConnectionOption(BookSource.STORYTELLER, "Storyteller", iconRes = R.drawable.ic_storyteller, tint = Color(0xFF0EA5A4), supported = true),
        ConnectionOption(BookSource.SILO, "Silo", iconRes = R.drawable.ic_silo, tint = Color(0xFF14B8A6), supported = true),
        ConnectionOption(BookSource.KOMGA, "Komga", iconRes = R.drawable.ic_komga, tint = Color(0xFF6C7AE0), supported = true),
        ConnectionOption(BookSource.KAVITA, "Kavita", iconRes = R.drawable.ic_kavita, tint = Color(0xFF4CAF7D), supported = true),
        ConnectionOption(BookSource.BOOKORBIT, "BookOrbit", iconRes = R.drawable.ic_bookorbit, tint = Color(0xFF4F8BFF), supported = true),
        ConnectionOption(BookSource.OPDS, "OPDS", iconRes = R.drawable.ic_opds, tint = Color(0xFF26A69A), supported = true),
    )

    val networkStorageOptions = listOf(
        ConnectionOption(BookSource.WEBDAV, "WebDAV", iconRes = R.drawable.ic_webdav, tint = Color(0xFFFF9500), supported = true),
        ConnectionOption(BookSource.TORBOX, "TorBox", iconRes = R.drawable.ic_torbox, tint = Color(0xFF00B8D9), supported = true),
        ConnectionOption(BookSource.PREMIUMIZE, "Premiumize", iconRes = R.drawable.ic_premiumize, tint = Color(0xFF2E7D32), supported = true),
        ConnectionOption(BookSource.REALDEBRID, "Real-Debrid", iconRes = R.drawable.ic_realdebrid, tint = Color(0xFF1976D2), supported = true),
        ConnectionOption(BookSource.SMB, "SMB share", iconVector = Icons.Default.Router, tint = Color(0xFFFF9500), supported = true),
    )

    val importOptions = listOf(
        ConnectionOption(BookSource.LOCAL, "Local files", iconVector = Icons.Default.Folder, tint = Color(0xFF1E90FF), supported = true),
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(if (eink.monochrome) colors.background else Color.Black),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .statusBarsPadding()
                .padding(bottom = 100.dp.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = onBack)
                Column(Modifier.padding(start = DS.Spacing.MD.scaled(metrics))) {
                    Text(
                        text = "BRING YOUR BOOKS",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption2.scaled(metrics),
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 4.sp,
                    )
                    Text(
                        text = "Add a source",
                        color = colors.primaryText,
                        fontSize = 32.sp.scaled(metrics),
                        lineHeight = 36.sp.scaled(metrics),
                        fontWeight = FontWeight.Bold,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Serif,
                    )
                }
            }

            AddSourceSection(
                mediaServerOptions = mediaServerOptions,
                networkStorageOptions = networkStorageOptions,
                importOptions = importOptions,
                onOptionClick = { option ->
                    if (!option.supported) {
                        return@AddSourceSection
                    } else {
                        onSourceChange(option.source)
                        onNavigateToServiceLogin(option.source, null)
                    }
                },
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )

            ConnectedSourcesSection(
                connections = connections,
                connectionHealth = authState.connectionHealth,
                isCheckingHealth = authState.isCheckingHealth,
                onToggle = { connId, enabled -> authViewModel.toggleConnection(connId, enabled) },
                onDelete = { connId -> authViewModel.removeConnection(connId) },
                onHealthCheck = { authViewModel.checkAllConnectionsHealth() },
                onEdit = { connection ->
                    onSourceChange(connection.source)
                    onNavigateToServiceLogin(connection.source, connection.id)
                },
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )

            ServerAdminSection(
                onServerManagementClick = onNavigateToServerManagement,
                onKomgaClick = onNavigateToKomgaHub,
                onSiloClick = onNavigateToSiloHub,
                onPlexHomeUsersClick = {
                    showPlexHomeUserSheet = true
                    authViewModel.loadPlexHomeUsers()
                },
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )
        }
    }

    if (showPlexHomeUserSheet) {
        PlexHomeUserSheet(
            users = authState.plexHomeUsers,
            loading = authState.plexHomeUsersLoading,
            errorMessage = authState.plexHomeUsersError,
            currentUserId = authState.plexCurrentUserId,
            onSwitch = { userId, pin -> authViewModel.switchPlexHomeUser(userId, pin) },
            onErrorAcknowledged = { authViewModel.clearPlexHomeUserError() },
            onDismiss = { showPlexHomeUserSheet = false },
        )
    }
}

@Composable
private fun ConnectedSourcesSection(
    connections: List<ProviderConnection>,
    connectionHealth: Map<String, Boolean>,
    isCheckingHealth: Boolean,
    onToggle: (String, Boolean) -> Unit,
    onDelete: (String) -> Unit,
    onHealthCheck: () -> Unit,
    onEdit: (ProviderConnection) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    val active = connections.filter { it.enabled || it.needsReauth }
    val paused = connections.filter { !it.enabled && !it.needsReauth }
    val hasAny = connections.isNotEmpty()

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Connected Sources",
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Headline.scaled(metrics),
                    fontWeight = FontWeight.SemiBold,
                )
                if (hasAny) {
                    Text(
                        text = "Tap to edit credentials, libraries, or remove",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
            }
            if (hasAny) {
                TextButton(onClick = onHealthCheck, enabled = !isCheckingHealth) {
                    if (isCheckingHealth) {
                        CircularProgressIndicator(
                            color = colors.accent,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(14.dp),
                        )
                    } else {
                        Icon(
                            Icons.Default.MonitorHeart,
                            contentDescription = null,
                            tint = colors.accent,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                    Spacer(Modifier.width(4.dp))
                    Text(
                        if (isCheckingHealth) "Checking…" else "Health",
                        color = colors.accent,
                        fontSize = DS.FontSize.Footnote.scaled(metrics),
                        fontWeight = FontWeight.Medium,
                    )
                }
            }
        }

        if (!hasAny) {
            SettingsCard {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(
                        Icons.Default.Dns,
                        contentDescription = null,
                        tint = colors.tertiaryText,
                        modifier = Modifier.size(40.dp),
                    )
                    Text(
                        "No sources connected yet",
                        color = colors.primaryText,
                        fontSize = DS.FontSize.Subheadline.scaled(metrics),
                        fontWeight = FontWeight.Medium,
                    )
                    Text(
                        "Use \"Add a Source\" below to get started.",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
                active.forEach { conn ->
                    SourceRow(
                        connection = conn,
                        health = connectionHealth[conn.id],
                        onToggle = { onToggle(conn.id, !conn.enabled) },
                        onDelete = { onDelete(conn.id) },
                        onEdit = { onEdit(conn) },
                    )
                }
            }

            if (paused.isNotEmpty()) {
                Text(
                    text = "Paused",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption2.scaled(metrics),
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
                )
                Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
                    paused.forEach { conn ->
                        SourceRow(
                            connection = conn,
                            health = connectionHealth[conn.id],
                            onToggle = { onToggle(conn.id, !conn.enabled) },
                            onDelete = { onDelete(conn.id) },
                            onEdit = { onEdit(conn) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SourceRow(
    connection: ProviderConnection,
    health: Boolean?,
    onToggle: () -> Unit,
    onDelete: () -> Unit,
    onEdit: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink
    var showDeleteDialog by remember { mutableStateOf(false) }
    val sourceTint = connection.source.toTint(colors.accent)
    val displayName = connection.name.ifBlank { "${connection.source.displayName} • ${connection.username}" }
    val isPaused = !connection.enabled
    val cardShape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(DS.Radius.Section)
    val iconShape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(DS.Radius.Medium)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(cardShape)
            .then(
                if (eink.suppressGradients) {
                    Modifier
                        .background(colors.background, cardShape)
                        .border(1.dp, colors.primaryText, cardShape)
                } else {
                    Modifier.background(colors.cardBackground.copy(alpha = if (isPaused) 0.55f else 0.9f), cardShape)
                }
            )
            .clickable(onClick = onEdit)
            .padding(DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {

        Box(
            modifier = Modifier
                .size(38.dp.scaled(metrics))
                .clip(iconShape)
                .background(colors.secondaryBackground, iconShape),
            contentAlignment = Alignment.Center,
        ) {
            BookSourceIcon(
                source = connection.source,
                tint = if (eink.monochrome || isPaused) colors.tertiaryText else sourceTint,
                modifier = Modifier.size(20.dp.scaled(metrics)),
            )
        }

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = displayName,
                color = if (isPaused) colors.secondaryText else colors.primaryText,
                fontSize = DS.FontSize.Body.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = connection.serverUrl,
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        when {
            connection.needsReauth -> StatusBadge(text = "SIGN IN", color = Color(0xFFFFB74D))
            isPaused -> StatusBadge(text = "PAUSED", color = Color(0xFF9CA3AF))

            health == false -> Icon(
                Icons.Default.Warning,
                contentDescription = "Offline",
                tint = if (eink.monochrome) colors.primaryText else Color(0xFFFFA726),
                modifier = Modifier.size(20.dp),
            )
            else -> Icon(
                Icons.Default.CheckCircle,
                contentDescription = "Online",
                tint = if (eink.monochrome) colors.primaryText else Color(0xFF22C55E),
                modifier = Modifier.size(20.dp),
            )
        }

        Switch(
            checked = connection.enabled,
            onCheckedChange = { onToggle() },
            modifier = Modifier.scale(0.85f),
        )

        IconButton(
            onClick = { showDeleteDialog = true },
            modifier = Modifier.size(32.dp),
        ) {
            Icon(
                Icons.Default.Delete,
                "Delete",
                tint = if (eink.monochrome) colors.primaryText else Color(0xFFFF6B6B),
                modifier = Modifier.size(18.dp),
            )
        }
    }

    if (showDeleteDialog) {
        AlertDialog(
            onDismissRequest = { showDeleteDialog = false },
            title = { Text("Delete Connection?", color = colors.primaryText) },
            text = {
                Text(
                    "This will remove ${connection.source.displayName} and all associated credentials.",
                    color = colors.secondaryText,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onDelete()
                        showDeleteDialog = false
                    },
                ) {
                    Text("Delete", color = if (eink.monochrome) colors.primaryText else Color(0xFFFF6B6B))
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteDialog = false }) {
                    Text("Cancel", color = colors.accent)
                }
            },
            containerColor = colors.cardBackground,
        )
    }
}

@Composable
private fun StatusBadge(text: String, color: Color) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink
    val shape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(DS.Radius.Pill)
    Surface(
        shape = shape,
        color = if (eink.suppressGradients) colors.secondaryBackground else color.copy(alpha = 0.85f),
        border = if (eink.suppressGradients) androidx.compose.foundation.BorderStroke(1.dp, colors.primaryText) else null,
    ) {
        Text(
            text = text,
            color = if (eink.monochrome) colors.primaryText else Color.White,
            fontSize = DS.FontSize.Caption2.scaled(metrics),
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(horizontal = DS.Spacing.SM.scaled(metrics), vertical = DS.Spacing.XXXS.scaled(metrics)),
        )
    }
}

@Composable
private fun AddSourceSection(
    mediaServerOptions: List<ConnectionOption>,
    networkStorageOptions: List<ConnectionOption>,
    importOptions: List<ConnectionOption>,
    onOptionClick: (ConnectionOption) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(26.dp.scaled(metrics)),
    ) {
        SourceGrid(title = "MEDIA SERVERS", options = mediaServerOptions, onOptionClick = onOptionClick)
        SourceGrid(title = "STORAGE & CLOUD", options = networkStorageOptions, onOptionClick = onOptionClick)
        SourceGrid(title = "IMPORT & FILES", options = importOptions, onOptionClick = onOptionClick)
    }
}

@Composable
private fun SourceGrid(
    title: String,
    options: List<ConnectionOption>,
    onOptionClick: (ConnectionOption) -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics))) {
        Text(
            text = title,
            color = colors.secondaryText,
            fontSize = 11.sp.scaled(metrics),
            fontWeight = FontWeight.Bold,
            letterSpacing = 4.sp,
            modifier = Modifier.padding(start = 4.dp),
        )

        options.chunked(3).forEach { row ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
            ) {
                row.forEach { option ->
                    SourceTile(
                        option = option,
                        modifier = Modifier.weight(1f),
                        onClick = { onOptionClick(option) },
                    )
                }
                if (row.size == 1) {
                    Spacer(Modifier.weight(1f))
                    Spacer(Modifier.weight(1f))
                } else if (row.size == 2) {
                    Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun SourceTile(
    option: ConnectionOption,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink
    val tint = option.tint
    val tileShape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(18.dp)
    val iconShape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(11.dp)

    Surface(
        modifier = modifier
            .clip(tileShape)
            .clickable(enabled = option.supported, onClick = onClick),
        shape = tileShape,
        color = colors.secondaryBackground,
        border = androidx.compose.foundation.BorderStroke(1.dp, colors.separator.copy(alpha = if (eink.suppressGradients) 1f else 0.4f)),
        tonalElevation = 0.dp,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .height(112.dp.scaled(metrics))
                .padding(vertical = 12.dp.scaled(metrics), horizontal = 8.dp.scaled(metrics)),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp.scaled(metrics)),
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp.scaled(metrics))
                    .clip(iconShape)
                    .then(
                        if (eink.suppressGradients) {
                            Modifier.border(1.dp, colors.primaryText, iconShape)
                        } else {
                            Modifier.background(Color.Black, iconShape)
                                .border(1.dp, colors.separator.copy(alpha = 0.35f), iconShape)
                        }
                    ),
                contentAlignment = Alignment.Center,
            ) {
                if (option.iconRes != null) {
                    Image(
                        painter = painterResource(option.iconRes),
                        contentDescription = null,
                        modifier = Modifier.size(28.dp.scaled(metrics)),
                        contentScale = ContentScale.Fit,
                    )
                } else if (option.iconVector != null) {
                    Icon(
                        imageVector = option.iconVector,
                        contentDescription = null,
                        tint = if (eink.monochrome) colors.primaryText else tint,
                        modifier = Modifier.size(24.dp.scaled(metrics)),
                    )
                } else {
                    BookSourceIcon(
                        source = option.source,
                        tint = if (eink.monochrome) colors.primaryText else tint,
                        modifier = Modifier.size(28.dp.scaled(metrics)),
                    )
                }
            }

            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    text = option.title,
                    color = colors.primaryText,
                    fontSize = 12.sp.scaled(metrics),
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun ServerAdminSection(
    onServerManagementClick: () -> Unit,
    onKomgaClick: () -> Unit,
    onSiloClick: () -> Unit,
    onPlexHomeUsersClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
    ) {
        Column(modifier = Modifier.padding(horizontal = 4.dp)) {
            Text(
                text = "Server Admin",
                color = colors.primaryText,
                fontSize = DS.FontSize.Headline.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Per-platform dashboards: users, sessions, and tasks",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
        }

        SettingsCard {
            ServerAdminRow(
                iconVector = Icons.Default.MonitorHeart,
                tint = Color(0xFF34C759),
                title = "All Servers",
                subtitle = "Health, cache refresh & connection controls",
                comingSoon = false,
                onClick = onServerManagementClick,
            )
            HorizontalDivider(color = dividerColor)
            ServerAdminRow(
                iconRes = R.drawable.ic_audiobookshelf,
                tint = Color(0xFFC8A45A),
                title = "AudioBookshelf",
                subtitle = "Health, cache refresh & connection controls",
                comingSoon = false,
                onClick = onServerManagementClick,
            )
            HorizontalDivider(color = dividerColor)
            ServerAdminRow(
                iconRes = R.drawable.ic_plex,
                tint = Color(0xFFE5A319),
                title = "Plex: Switch User",
                onClick = onPlexHomeUsersClick,
            )
            HorizontalDivider(color = dividerColor)
            ServerAdminRow(
                iconRes = R.drawable.ic_jellyfin,
                tint = Color(0xFF9C6BDB),
                title = "Jellyfin / Emby",
                subtitle = "Health, cache refresh & connection controls",
                comingSoon = false,
                onClick = onServerManagementClick,
            )
            HorizontalDivider(color = dividerColor)
            ServerAdminRow(
                iconRes = R.drawable.ic_grimmory,
                tint = colors.accent,
                title = "Grimmory",
                subtitle = "Books, shelves & reading stats",
                comingSoon = false,
                onClick = onServerManagementClick,
            )
            HorizontalDivider(color = dividerColor)
            ServerAdminRow(
                iconRes = R.drawable.ic_komga,
                tint = Color(0xFF6C7AE0),
                title = "Komga",
                subtitle = "Libraries, read lists & collections",
                comingSoon = false,
                onClick = onKomgaClick,
            )
            HorizontalDivider(color = dividerColor)
            ServerAdminRow(
                iconRes = R.drawable.ic_silo,
                tint = Color(0xFF14B8A6),
                title = "Silo",
                subtitle = "Server stats, status & users",
                comingSoon = false,
                onClick = onSiloClick,
            )
        }
    }
}

@Composable
private fun ServerAdminRow(
    iconRes: Int? = null,
    iconVector: ImageVector? = null,
    tint: Color,
    title: String,
    subtitle: String? = null,
    comingSoon: Boolean = true,
    onClick: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink
    val iconShape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else CircleShape

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp.scaled(metrics))
                .clip(iconShape)
                .then(
                    if (eink.suppressGradients) {
                        Modifier.border(1.dp, colors.primaryText, iconShape)
                    } else {
                        Modifier.background(tint.copy(alpha = 0.12f), iconShape)
                    }
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (iconRes != null) {
                Image(
                    painter = painterResource(iconRes),
                    contentDescription = null,
                    modifier = Modifier.size(20.dp.scaled(metrics)),
                    contentScale = ContentScale.Fit,
                )
            } else if (iconVector != null) {
                Icon(
                    imageVector = iconVector,
                    contentDescription = null,
                    tint = if (eink.monochrome) colors.primaryText else tint,
                    modifier = Modifier.size(20.dp.scaled(metrics)),
                )
            }
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                color = colors.primaryText,
                fontSize = DS.FontSize.Body.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
            )
            if (subtitle != null) {
                Text(
                    text = subtitle,
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
        }
        if (comingSoon) {
            Surface(
                shape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(DS.Radius.Pill),
                color = colors.secondaryBackground,
                border = if (eink.suppressGradients) androidx.compose.foundation.BorderStroke(1.dp, colors.primaryText) else null,
            ) {
                Text(
                    "Unavailable",
                    color = if (eink.monochrome) colors.primaryText else colors.secondaryText,
                    fontSize = DS.FontSize.Caption2.scaled(metrics),
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = DS.Spacing.SM.scaled(metrics), vertical = DS.Spacing.XXXS.scaled(metrics)),
                )
            }
        } else {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.tertiaryText,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

private fun BookSource.toTint(accent: Color): Color = when (this) {
    BookSource.GRIMMORY -> accent
    BookSource.STORYTELLER -> Color(0xFF0EA5A4)
    BookSource.AUDIOBOOKSHELF -> Color(0xFFC8A45A)
    BookSource.JELLYFIN -> Color(0xFF9C6BDB)
    BookSource.PLEX -> Color(0xFFE5A319)
    BookSource.EMBY -> Color(0xFF4CAF7D)
    BookSource.KOMGA -> Color(0xFF6C7AE0)
    BookSource.KAVITA -> Color(0xFF4CAF7D)
    BookSource.BOOKORBIT -> Color(0xFF4F8BFF)
    BookSource.SILO -> Color(0xFF14B8A6)
    BookSource.OPDS -> Color(0xFF26A69A)
    BookSource.WEBDAV -> Color(0xFF15B8D6)
    BookSource.TORBOX -> Color(0xFF00B8D9)
    BookSource.PREMIUMIZE -> Color(0xFF2E7D32)
    BookSource.REALDEBRID -> Color(0xFF1976D2)
    BookSource.SMB -> Color(0xFF16B5E4)
    BookSource.LOCAL -> Color(0xFF1E88E5)
}
