package com.enve.app.ui.screens

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.core.data.model.BookSource
import com.enve.app.ui.components.*
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.ProviderSyncStatus
import com.enve.app.viewmodel.SyncCenterState
import com.enve.hearth.design.hearthDisplay
import java.time.Instant
import java.time.ZoneId
import java.time.Duration
import java.time.format.DateTimeFormatter

@Composable
fun SyncCenterScreen(
    state: SyncCenterState,
    onBack: () -> Unit,
    onSyncNow: () -> Unit,
    onAutoSyncChange: (Boolean) -> Unit,
    onSyncOnCellularChange: (Boolean) -> Unit,
    onKoreaderUsernameChange: (String) -> Unit,
    onKoreaderPasswordChange: (String) -> Unit,
    onSaveKoreaderCredentials: () -> Unit,
    onTestKoreaderAuth: () -> Unit,
    onClearKoreaderCredentials: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    val lastSync = if (state.lastSyncTime <= 0L) {
        "Never"
    } else {
        val instant = Instant.ofEpochMilli(state.lastSyncTime)
        val duration = Duration.between(instant, Instant.now())
        when {
            duration.toMinutes() < 1 -> "Just now"
            duration.toMinutes() < 60 -> "${duration.toMinutes()} min ago"
            duration.toHours() < 24 -> "${duration.toHours()} hr ago"
            duration.toDays() < 7 -> "${duration.toDays()} days ago"
            else -> DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
                .format(instant.atZone(ZoneId.systemDefault()))
        }
    }

    SettingsScreenLayout(animatedBackground = true) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .verticalScroll(rememberScrollState())
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
                    text = "Sync Center",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(DS.Spacing.XL.scaled(metrics)),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                ) {
                    val pulse = if (EnveTheme.isEink) {
                        1f
                    } else {
                        val transition = rememberInfiniteTransition(label = "cloud_pulse")
                        val animated by transition.animateFloat(
                            initialValue = 1f,
                            targetValue = if (state.isSyncingAll) 1.15f else 1f,
                            animationSpec = infiniteRepeatable(
                                animation = tween(800, easing = EaseInOutSine),
                                repeatMode = RepeatMode.Reverse,
                            ),
                            label = "cloud_pulse",
                        )
                        animated
                    }

                    Box(
                        modifier = Modifier
                            .size(72.dp.scaled(metrics))
                            .scale(if (state.isSyncingAll) pulse else 1f)
                            .clip(CircleShape)
                            .background(
                                if (state.isSyncingAll) colors.accent.copy(alpha = 0.18f)
                                else colors.secondaryBackground
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = if (state.isSyncingAll) Icons.Default.Sync else Icons.Default.CloudDone,
                            contentDescription = null,
                            tint = if (state.isSyncingAll) colors.accent else Color(0xFF6F8F6A),
                            modifier = Modifier.size(32.dp.scaled(metrics)),
                        )
                    }

                    Text(
                        text = if (state.isSyncingAll) "Syncing…" else "Up to Date",
                        color = colors.primaryText,
                        fontSize = DS.FontSize.Title3.scaled(metrics),
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = "Last sync: $lastSync",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                    if (state.pendingCount > 0) {
                        Text(
                            text = "${state.pendingCount} pending",
                            color = colors.accent,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                        )
                    }
                    state.lastSyncResult?.let {
                        Text(text = it, color = colors.tertiaryText, fontSize = DS.FontSize.Caption2.scaled(metrics))
                    }
                }
            }

            if (state.providers.isNotEmpty()) {
                SettingsSectionHeader(title = "Connected Services")
                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Column(modifier = Modifier.padding(vertical = DS.Spacing.SM.scaled(metrics))) {
                        state.providers.forEachIndexed { index, provider ->
                            ProviderSyncRow(provider = provider, colors = colors, metrics = metrics)
                            if (index < state.providers.lastIndex) {
                                HorizontalDivider(
                                    color = colors.separator.copy(alpha = 0.3f),
                                    modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
                                )
                            }
                        }
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(modifier = Modifier.padding(vertical = DS.Spacing.SM.scaled(metrics))) {
                    SettingsToggleRow(
                        icon = Icons.Default.Replay,
                        iconTint = colors.accent,
                        title = "Auto sync on app launch",
                        subtitle = "Refreshes library metadata each time app starts.",
                        checked = state.autoSyncOnLaunch,
                        onCheckedChange = onAutoSyncChange,
                    )
                    HorizontalDivider(color = colors.separator.copy(alpha = 0.3f), modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)))
                    SettingsToggleRow(
                        icon = Icons.Default.SignalCellularAlt,
                        iconTint = Color(0xFF64748B),
                        title = "Allow sync on cellular",
                        subtitle = "Permit sync refresh outside of Wi-Fi.",
                        checked = state.syncOnCellular,
                        onCheckedChange = onSyncOnCellularChange,
                    )
                }
            }

            val hasGrimmory = state.providers.any { it.source == BookSource.GRIMMORY }
            if (hasGrimmory || state.koreaderEnabled) {
                KoreaderSyncSection(
                    state = state,
                    onUsernameChange = onKoreaderUsernameChange,
                    onPasswordChange = onKoreaderPasswordChange,
                    onSave = onSaveKoreaderCredentials,
                    onTest = onTestKoreaderAuth,
                    onClear = onClearKoreaderCredentials,
                    colors = colors,
                    metrics = metrics,
                )
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(DS.Spacing.LG.scaled(metrics)),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(999.dp))
                            .background(colors.accent)
                            .enveClickable(enabled = !state.isSyncingAll, onClick = onSyncNow)
                            .padding(vertical = DS.Spacing.MD.scaled(metrics)),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (state.isSyncingAll) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                            ) {
                                CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp)
                                Text("Syncing…", color = Color.White, fontSize = DS.FontSize.Subheadline.scaled(metrics), fontWeight = FontWeight.SemiBold)
                            }
                        } else {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                            ) {
                                Icon(Icons.Default.CloudSync, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
                                Text("Sync Now", color = Color.White, fontSize = DS.FontSize.Subheadline.scaled(metrics), fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                }
            }

            state.error?.let {
                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(DS.Spacing.MD.scaled(metrics)),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                    ) {
                        Icon(Icons.Default.Error, contentDescription = null, tint = Color(0xFFB3453E))
                        Text(it, color = Color(0xFFB3453E), fontSize = DS.FontSize.Caption.scaled(metrics))
                    }
                }
            }
        }
    }
}

@Composable
private fun ProviderSyncRow(
    provider: ProviderSyncStatus,
    colors: com.enve.app.ui.theme.EnveColorScheme,
    metrics: com.enve.app.ui.theme.AdaptiveMetrics,
) {
    val lastSync = provider.lastSyncedAt?.let { ts ->
        val instant = Instant.ofEpochMilli(ts)
        val duration = Duration.between(instant, Instant.now())
        when {
            duration.toMinutes() < 1 -> "Just now"
            duration.toMinutes() < 60 -> "${duration.toMinutes()}m ago"
            duration.toHours() < 24 -> "${duration.toHours()}h ago"
            else -> "${duration.toDays()}d ago"
        }
    } ?: "Never synced"

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(colors.accent.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Default.Cloud,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(18.dp),
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(provider.name, color = colors.primaryText, fontSize = DS.FontSize.Body.scaled(metrics), fontWeight = FontWeight.Medium)
            Text(
                "${provider.source.displayName} • $lastSync",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
        }
        if (provider.isSyncing) {
            CircularProgressIndicator(modifier = Modifier.size(16.dp), color = colors.accent, strokeWidth = 2.dp)
        } else {
            Icon(
                imageVector = Icons.Default.CheckCircle,
                contentDescription = null,
                tint = Color(0xFF6F8F6A),
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun KoreaderSyncSection(
    state: SyncCenterState,
    onUsernameChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onSave: () -> Unit,
    onTest: () -> Unit,
    onClear: () -> Unit,
    colors: com.enve.app.ui.theme.EnveColorScheme,
    metrics: com.enve.app.ui.theme.AdaptiveMetrics,
) {
    var showPassword by remember { mutableStateOf(false) }

    SettingsSectionHeader(title = "KOReader Sync")
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(DS.Spacing.MD.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        ) {
            Text(
                text = "Enable KOReader progress sync via Grimmory's kosync endpoint.",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )

            OutlinedTextField(
                value = state.koreaderUsername,
                onValueChange = onUsernameChange,
                label = { Text("KOReader Username") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = colors.primaryText,
                    unfocusedTextColor = colors.primaryText,
                    focusedBorderColor = colors.accent,
                ),
            )

            OutlinedTextField(
                value = state.koreaderPassword,
                onValueChange = onPasswordChange,
                label = { Text("KOReader Password") },
                singleLine = true,
                visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                trailingIcon = {
                    IconButton(onClick = { showPassword = !showPassword }) {
                        Icon(
                            if (showPassword) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                            contentDescription = null,
                            tint = colors.secondaryText,
                        )
                    }
                },
                modifier = Modifier.fillMaxWidth(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = colors.primaryText,
                    unfocusedTextColor = colors.primaryText,
                    focusedBorderColor = colors.accent,
                ),
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
            ) {
                OutlinedButton(
                    onClick = onSave,
                    modifier = Modifier.weight(1f),
                    border = androidx.compose.foundation.BorderStroke(1.dp, colors.accent),
                ) {
                    Text("Save", color = colors.accent)
                }
                OutlinedButton(
                    onClick = onTest,
                    enabled = !state.koreaderTesting && state.koreaderUsername.isNotBlank() && state.koreaderPassword.isNotBlank(),
                    modifier = Modifier.weight(1f),
                    border = androidx.compose.foundation.BorderStroke(1.dp, colors.accent),
                ) {
                    if (state.koreaderTesting) {
                        CircularProgressIndicator(modifier = Modifier.size(14.dp), color = colors.accent, strokeWidth = 2.dp)
                    } else {
                        Text("Test", color = colors.accent)
                    }
                }
                if (state.koreaderEnabled) {
                    OutlinedButton(
                        onClick = onClear,
                        border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFFB3453E)),
                    ) {
                        Text("Clear", color = Color(0xFFB3453E))
                    }
                }
            }

            state.koreaderTestResult?.let { result ->
                val isSuccess = result == "Connected"
                Text(
                    text = result,
                    color = if (isSuccess) Color(0xFF6F8F6A) else Color(0xFFB3453E),
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
        }
    }
}
