package com.enve.app.ui.screens

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.ui.components.*
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.einkAwareBackground
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.StorageHubState

@Composable
fun StorageHubScreen(
    state: StorageHubState,
    onRefresh: () -> Unit,
    onClearCache: () -> Unit,
    onClearDownloads: () -> Unit,
    onBack: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    var showClearDownloadsConfirm by remember { mutableStateOf(false) }

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
                    text = "Storage",
                    color = colors.primaryText,
                    style = com.enve.hearth.design.hearthDisplay(22.sp),
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = DS.Spacing.MD.scaled(metrics)),
                )

                IconButton(
                    onClick = onRefresh,
                    modifier = Modifier.background(colors.cardBackground.copy(alpha = 0.8f), CircleShape),
                ) {
                    Icon(Icons.Default.Refresh, contentDescription = "Refresh", tint = colors.primaryText)
                }
            }

            if (state.isLoading) {
                Column(
                    modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                ) {
                    HeroSkeleton()
                    repeat(3) { BookRowSkeleton() }
                }
            } else {
                val cache = state.cacheSizeMb.toFloatOrNull() ?: 0f
                val appData = state.appDataSizeMb.toFloatOrNull() ?: 0f
                val downloaded = state.downloadedSizeMb.toFloatOrNull() ?: 0f
                val total = cache + appData + downloaded + 100f

                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(DS.Spacing.LG.scaled(metrics)),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        StorageDonutChart(
                            segments = listOf(
                                StorageSegment("Cache", cache, Color(0xFFF5921A)),
                                StorageSegment("App Data", appData, Color(0xFF64748B)),
                                StorageSegment("Downloads", downloaded, Color(0xFF6F8F6A)),
                            ),
                            totalMb = total,
                        )
                        Spacer(Modifier.height(DS.Spacing.MD.scaled(metrics)))
                        StorageLegend(
                            segments = listOf(
                                StorageSegment("Cache", cache, Color(0xFFF5921A)),
                                StorageSegment("App Data", appData, Color(0xFF64748B)),
                                StorageSegment("Downloads (${state.downloadedItems} items)", downloaded, Color(0xFF6F8F6A)),
                            ),
                        )
                    }
                }

                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(DS.Spacing.MD.scaled(metrics)),
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                    ) {
                        StorageStatRow(
                            icon = Icons.Default.Storage,
                            label = "Cache",
                            value = "${state.cacheSizeMb} MB",
                            color = Color(0xFFF5921A),
                        )
                        HorizontalDivider(color = colors.separator.copy(alpha = 0.3f))
                        StorageStatRow(
                            icon = Icons.Default.Folder,
                            label = "App Data",
                            value = "${state.appDataSizeMb} MB",
                            color = Color(0xFF64748B),
                        )
                        HorizontalDivider(color = colors.separator.copy(alpha = 0.3f))
                        StorageStatRow(
                            icon = Icons.Default.Download,
                            label = "Downloaded Items",
                            value = "${state.downloadedItems} · ${state.downloadedSizeMb} MB",
                            color = Color(0xFF6F8F6A),
                        )
                    }
                }

                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(DS.Spacing.LG.scaled(metrics)),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                    ) {
                        StorageActionButton(
                            icon = Icons.Default.CleaningServices,
                            label = "Clear App Cache",
                            color = colors.accent,
                            filled = true,
                            enabled = !state.isClearingCache && !state.isClearingDownloads,
                            isLoading = state.isClearingCache,
                            onClick = onClearCache,
                        )

                        HorizontalDivider(color = colors.separator.copy(alpha = 0.3f))

                        Text(
                            text = "Remove downloaded audiobooks, comics, PDFs, and ebooks from this device. Library entries and cloud/server progress stay intact.",
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                            modifier = Modifier.fillMaxWidth(),
                        )

                        StorageActionButton(
                            icon = Icons.Default.Delete,
                            label = if (state.downloadedItems == 0) "No Downloads to Remove" else "Remove All Downloads",
                            color = Color(0xFFB3453E),
                            filled = false,
                            enabled = state.downloadedItems > 0 && !state.isClearingCache && !state.isClearingDownloads,
                            isLoading = state.isClearingDownloads,
                            onClick = { showClearDownloadsConfirm = true },
                        )
                    }
                }

                state.error?.let {
                    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(DS.Spacing.MD.scaled(metrics)),
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

    if (showClearDownloadsConfirm) {
        AlertDialog(
            onDismissRequest = { showClearDownloadsConfirm = false },
            title = { Text("Remove all downloads?") },
            text = {
                Text(
                    "This removes ${state.downloadedItems} offline ${if (state.downloadedItems == 1) "item" else "items"} from this device. Your library and synced progress are not deleted.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showClearDownloadsConfirm = false
                        onClearDownloads()
                    },
                ) {
                    Text("Remove Downloads", color = Color(0xFFB3453E))
                }
            },
            dismissButton = {
                TextButton(onClick = { showClearDownloadsConfirm = false }) {
                    Text("Cancel")
                }
            },
        )
    }
}

@Composable
private fun StorageStatRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    value: String,
    color: Color,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp.scaled(metrics))
                .clip(CircleShape)
                .background(color.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
        }
        Text(
            text = label,
            color = colors.primaryText,
            fontSize = DS.FontSize.Body.scaled(metrics),
            fontWeight = FontWeight.Medium,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = value,
            color = colors.secondaryText,
            fontSize = DS.FontSize.Subheadline.scaled(metrics),
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun StorageActionButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    color: Color,
    filled: Boolean,
    enabled: Boolean,
    isLoading: Boolean,
    onClick: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val einkActive = EnveTheme.eink.active
    val shape = if (einkActive) RoundedCornerShape(4.dp) else RoundedCornerShape(999.dp)
    val contentColor = when {
        !enabled -> colors.tertiaryText
        einkActive -> colors.primaryText
        filled -> Color.White
        else -> color
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .einkAwareBackground(
                brush = SolidColor(if (filled && enabled) color else Color.Transparent),
                einkFill = colors.background,
                einkBorder = if (enabled) color else colors.separator,
                shape = shape,
            )
            .then(
                if (einkActive || (filled && enabled)) {
                    Modifier
                } else {
                    Modifier.border(1.dp, if (enabled) color else colors.separator, shape)
                },
            )
            .enveClickable(enabled = enabled, onClick = onClick)
            .padding(vertical = DS.Spacing.MD.scaled(metrics)),
        contentAlignment = Alignment.Center,
    ) {
        if (isLoading) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                color = contentColor,
                strokeWidth = 2.dp,
            )
        } else {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = contentColor,
                    modifier = Modifier.size(20.dp),
                )
                Text(
                    label,
                    color = contentColor,
                    fontSize = DS.FontSize.Subheadline.scaled(metrics),
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}
