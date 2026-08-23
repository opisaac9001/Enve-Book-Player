package com.enve.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.AdminPanelSettings
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Refresh
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.app.ui.components.BookSourceIcon
import com.enve.hearth.design.hearthDisplay
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsNavigationRow
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.SettingsSectionHeader
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.SiloAdminState
import com.enve.app.viewmodel.SiloAdminViewModel
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.silo.dto.SiloAdminServerStatusDto
import com.enve.silo.dto.SiloAdminStatsDto
import com.enve.silo.dto.SiloAdminUserDto

private val SiloTint = Color(0xFF6F8F6A)

@Composable
fun SiloAdminHubScreen(
    onBack: () -> Unit,
    onConnectSilo: () -> Unit,
    viewModel: SiloAdminViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsState()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)

    LaunchedEffect(state.selectedConnectionId) {
        if (state.selectedConnectionId != null && state.stats == null && !state.isLoading) {
            viewModel.refresh()
        }
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
                    text = "Silo",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
                Spacer(modifier = Modifier.weight(1f))
                TextButton(onClick = viewModel::refresh, enabled = state.selectedConnection != null && !state.isLoading) {
                    Icon(Icons.Default.Refresh, contentDescription = null, tint = SiloTint)
                    Text("Refresh", color = SiloTint)
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(DS.Spacing.XL.scaled(metrics)),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                ) {
                    BookSourceIcon(
                        source = BookSource.SILO,
                        tint = SiloTint,
                        modifier = Modifier.height(64.dp.scaled(metrics)),
                    )
                    Text(
                        text = "Server Administration",
                        color = colors.primaryText,
                        style = hearthDisplay(20.sp),
                    )
                    Text(
                        text = subtitleFor(state),
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
            }

            if (state.adminConnections.isEmpty()) {
                SiloNoAdminCard(onConnectSilo = onConnectSilo)
            } else {
                if (state.adminConnections.size > 1) {
                    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                        SettingsSectionHeader(title = "Active Server")
                        state.adminConnections.forEach { connection ->
                            SiloServerRow(
                                connection = connection,
                                selected = connection.id == state.selectedConnectionId,
                                onClick = { viewModel.selectConnection(connection.id) },
                            )
                            if (connection != state.adminConnections.last()) HorizontalDivider(color = dividerColor)
                        }
                    }
                }

                if (state.isLoading && state.stats == null) {
                    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(DS.Spacing.LG.scaled(metrics)),
                            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            CircularProgressIndicator(color = SiloTint)
                            Text("Loading Silo admin data", color = colors.secondaryText)
                        }
                    }
                }

                SiloStatsCard(state.stats)
                SiloServerStatusCard(state.serverStatus)
                SiloUsersCard(state.users)
                SiloDeferredControlsCard()
            }
        }
    }
}

@Composable
private fun SiloNoAdminCard(onConnectSilo: () -> Unit) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(DS.Spacing.LG.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        ) {
            Icon(Icons.Default.AdminPanelSettings, contentDescription = null, tint = SiloTint)
            Text("No Silo admin server confirmed", color = colors.primaryText, fontWeight = FontWeight.SemiBold)
            Text(
                "Connect with a Silo account whose /auth/me role is admin. Enve keeps admin controls hidden until the server confirms that role.",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
            Button(
                onClick = onConnectSilo,
                shape = RoundedCornerShape(999.dp),
                colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = Color.White),
            ) { Text("Connect Silo") }
        }
    }
}

@Composable
private fun SiloServerRow(connection: ProviderConnection, selected: Boolean, onClick: () -> Unit) {
    SettingsNavigationRow(
        icon = if (selected) Icons.Default.CheckCircle else Icons.AutoMirrored.Filled.MenuBook,
        iconTint = SiloTint,
        title = connection.name,
        subtitle = connection.serverUrl,
        onClick = onClick,
    )
}

@Composable
private fun SiloStatsCard(stats: SiloAdminStatsDto?) {
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG)) {
        SettingsSectionHeader(title = "Library Stats")
        AdminMetricRow(Icons.AutoMirrored.Filled.MenuBook, "Items", stats?.totalItems?.toString() ?: "--")
        AdminMetricRow(Icons.Default.Storage, "Files", stats?.totalFiles?.toString() ?: "--")
        AdminMetricRow(Icons.Default.Group, "Users", stats?.totalUsers?.toString() ?: "--")
        AdminMetricRow(Icons.Default.PlayCircle, "Active streams", stats?.activeStreams?.toString() ?: "--")
        AdminMetricRow(Icons.Default.Storage, "Storage", stats?.totalStorageBytes?.let(::formatBytes) ?: "--")
    }
}

@Composable
private fun SiloServerStatusCard(status: SiloAdminServerStatusDto?) {
    val restartText = when {
        status == null -> "--"
        status.restartRequested -> "Restart requested"
        status.restartRequired -> status.restartRequiredReason?.takeIf { it.isNotBlank() } ?: "Restart required"
        else -> "Healthy"
    }
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG)) {
        SettingsSectionHeader(title = "Server Status")
        AdminMetricRow(Icons.Default.CheckCircle, "Restart", restartText)
        AdminMetricRow(Icons.Default.Warning, "Started", status?.startedAt ?: "--")
    }
}

@Composable
private fun SiloUsersCard(users: List<SiloAdminUserDto>) {
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG)) {
        SettingsSectionHeader(title = "Users")
        if (users.isEmpty()) {
            AdminMetricRow(Icons.Default.Group, "Accounts", "--")
        } else {
            users.take(6).forEach { user ->
                AdminMetricRow(
                    icon = Icons.Default.Group,
                    label = user.username,
                    value = if (user.enabled) user.role else "${user.role} disabled",
                )
            }
            if (users.size > 6) {
                AdminMetricRow(Icons.Default.Group, "More", "${users.size - 6} additional users")
            }
        }
    }
}

@Composable
private fun SiloDeferredControlsCard() {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = "Controls")
        Column(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics))) {
            Text(
                "Read-only admin data is enabled. User edits, scans, metadata refresh, restart, and library mutation need endpoint-specific screens before they are exposed here.",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
        }
    }
}

@Composable
private fun AdminMetricRow(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, value: String) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = SiloTint)
        Text(label, color = colors.primaryText, modifier = Modifier.weight(1f))
        Text(value, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
    }
}

private fun subtitleFor(state: SiloAdminState): String = when (state.adminConnections.size) {
    0 -> "Admin access is hidden until Silo confirms your account role."
    1 -> "Admin on ${state.selectedConnection?.name.orEmpty()}"
    else -> "${state.adminConnections.size} admin servers"
}

private fun formatBytes(value: Long): String {
    if (value <= 0L) return "0 B"
    val units = listOf("B", "KB", "MB", "GB", "TB", "PB")
    var amount = value.toDouble()
    var index = 0
    while (amount >= 1024.0 && index < units.lastIndex) {
        amount /= 1024.0
        index += 1
    }
    return if (index == 0) "${amount.toLong()} ${units[index]}" else "%.1f %s".format(amount, units[index])
}
