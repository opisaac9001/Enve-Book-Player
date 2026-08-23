package com.enve.app.ui.screens

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.core.data.model.BookSource
import com.enve.hearth.design.hearthDisplay
import com.enve.core.data.model.ProviderConnection
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsNavigationRow
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.SettingsSectionHeader
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.ui.auth.AuthViewModel

private val KomgaTint = Color(0xFF64748B)

@Composable
fun KomgaHubScreen(
    authViewModel: AuthViewModel,
    onBack: () -> Unit,
    onOpenUsers: (String) -> Unit,
    onOpenLibraries: (String) -> Unit,
    onOpenCollections: (String) -> Unit,
    onOpenReadLists: (String) -> Unit,
    onOpenServerInfo: (String) -> Unit,
    onOpenAnnouncements: (String) -> Unit,
    onOpenHistory: (String) -> Unit,
    onOpenApiKeys: (String) -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)
    val connections by authViewModel.listConnections().collectAsState(initial = emptyList())
    val adminConnections = connections.filter { it.source == BookSource.KOMGA && it.isAdmin && it.enabled }
    var selectedId by remember(adminConnections) {
        mutableStateOf(adminConnections.firstOrNull()?.id)
    }
    val selected = adminConnections.find { it.id == selectedId }

    val glowScale = if (EnveTheme.isEink) {
        1f
    } else {
        val transition = rememberInfiniteTransition(label = "komga_pulse")
        val animated by transition.animateFloat(
            initialValue = 1f,
            targetValue = 1.04f,
            animationSpec = infiniteRepeatable(
                animation = tween(3000, easing = EaseInOutSine),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "glow",
        )
        animated
    }

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
                    text = "Komga",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(DS.Spacing.XL.scaled(metrics)),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                ) {
                    val tileShape = if (EnveTheme.eink.sharpCorners) RoundedCornerShape(4.dp) else CircleShape
                    Box(
                        modifier = Modifier
                            .size(80.dp.scaled(metrics))
                            .scale(glowScale)
                            .clip(tileShape)
                            .then(
                                if (EnveTheme.eink.suppressGradients) {
                                    Modifier.border(1.dp, colors.primaryText, tileShape)
                                } else {
                                    Modifier.background(KomgaTint.copy(alpha = 0.14f))
                                }
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Default.AdminPanelSettings,
                            contentDescription = null,
                            tint = if (EnveTheme.eink.monochrome) colors.primaryText else KomgaTint,
                            modifier = Modifier.size(36.dp.scaled(metrics)),
                        )
                    }

                    Text(
                        text = "Server Administration",
                        color = colors.primaryText,
                        style = hearthDisplay(20.sp),
                    )
                    val subtitle = when (adminConnections.size) {
                        0 -> "No admin Komga server detected."
                        1 -> "Admin on ${selected?.name ?: ""}"
                        else -> "${adminConnections.size} admin servers"
                    }
                    Text(
                        text = subtitle,
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
            }

            if (adminConnections.size > 1) {
                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    SettingsSectionHeader(title = "Active Server")
                    adminConnections.forEach { conn ->
                        ServerPickRow(
                            connection = conn,
                            selected = conn.id == selectedId,
                            onClick = { selectedId = conn.id },
                        )
                    }
                }
            }

            val activeId = selectedId
            if (activeId == null) {
                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Box(modifier = Modifier.fillMaxWidth().padding(DS.Spacing.LG)) {
                        Text(
                            "Sign in to a Komga server with an admin account to manage it from here.",
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                        )
                    }
                }
            } else {
                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    SettingsSectionHeader(title = "Manage")
                    SettingsNavigationRow(
                        icon = Icons.Default.People,
                        iconTint = KomgaTint,
                        title = "Users",
                        subtitle = "Add, remove, and edit Komga users",
                        onClick = { onOpenUsers(activeId) },
                    )
                    HorizontalDivider(color = dividerColor)
                    SettingsNavigationRow(
                        icon = Icons.AutoMirrored.Filled.LibraryBooks,
                        iconTint = KomgaTint,
                        title = "Libraries",
                        subtitle = "Create libraries, trigger scans, manage paths",
                        onClick = { onOpenLibraries(activeId) },
                    )
                    HorizontalDivider(color = dividerColor)
                    SettingsNavigationRow(
                        icon = Icons.Default.Collections,
                        iconTint = KomgaTint,
                        title = "Collections",
                        subtitle = "Create and edit collections of series",
                        onClick = { onOpenCollections(activeId) },
                    )
                    HorizontalDivider(color = dividerColor)
                    SettingsNavigationRow(
                        icon = Icons.AutoMirrored.Filled.MenuBook,
                        iconTint = KomgaTint,
                        title = "Read Lists",
                        subtitle = "Curate ordered reading lists across libraries",
                        onClick = { onOpenReadLists(activeId) },
                    )
                }

                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    SettingsSectionHeader(title = "Server")
                    SettingsNavigationRow(
                        icon = Icons.Default.Dns,
                        iconTint = KomgaTint,
                        title = "Server Info",
                        subtitle = "Version, health, and running tasks",
                        onClick = { onOpenServerInfo(activeId) },
                    )
                    HorizontalDivider(color = dividerColor)
                    SettingsNavigationRow(
                        icon = Icons.Default.Campaign,
                        iconTint = KomgaTint,
                        title = "Announcements",
                        subtitle = "Server-wide notices",
                        onClick = { onOpenAnnouncements(activeId) },
                    )
                    HorizontalDivider(color = dividerColor)
                    SettingsNavigationRow(
                        icon = Icons.Default.History,
                        iconTint = KomgaTint,
                        title = "History",
                        subtitle = "Recent server events and audit log",
                        onClick = { onOpenHistory(activeId) },
                    )
                    HorizontalDivider(color = dividerColor)
                    SettingsNavigationRow(
                        icon = Icons.Default.Key,
                        iconTint = KomgaTint,
                        title = "API Keys",
                        subtitle = "Manage personal API tokens",
                        onClick = { onOpenApiKeys(activeId) },
                    )
                }
            }

            Spacer(Modifier.height(80.dp.scaled(metrics)))
        }
    }
}

@Composable
private fun ServerPickRow(
    connection: ProviderConnection,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink
    val iconShape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else CircleShape
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(horizontal = DS.Spacing.MD.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(28.dp.scaled(metrics))
                .clip(iconShape)
                .then(
                    if (eink.suppressGradients) {
                        Modifier.border(1.dp, colors.primaryText, iconShape)
                    } else {
                        Modifier.background(
                            if (selected) KomgaTint else KomgaTint.copy(alpha = 0.18f),
                            iconShape,
                        )
                    }
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (selected) Icons.Default.Check else Icons.Default.Dns,
                contentDescription = null,
                tint = when {
                    eink.monochrome -> colors.primaryText
                    selected -> Color.White
                    else -> KomgaTint
                },
                modifier = Modifier.size(16.dp.scaled(metrics)),
            )
        }
        Column(modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)).weight(1f)) {
            Text(
                connection.name,
                color = colors.primaryText,
                fontSize = DS.FontSize.Body.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
            )
            Text(connection.serverUrl, color = colors.tertiaryText, fontSize = DS.FontSize.Caption2.scaled(metrics))
        }
    }
}
