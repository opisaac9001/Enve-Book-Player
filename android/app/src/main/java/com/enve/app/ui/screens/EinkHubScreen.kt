package com.enve.app.ui.screens

import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.eink.EinkDeviceProfile
import com.enve.app.eink.EinkDisplayMode
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsHeroHeader
import com.enve.app.ui.components.SettingsNavigationRow
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.SettingsSectionHeader
import androidx.compose.foundation.border
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.hearth.design.hearthDisplay

@Composable
fun EinkHubScreen(
    displayMode: EinkDisplayMode,
    deviceProfile: EinkDeviceProfile,
    refreshStrength: Int,
    boldText: Boolean,
    fullRefreshEveryN: Int,
    dynamicBackgroundEnabled: Boolean,
    onDisplayModeChange: (EinkDisplayMode) -> Unit,
    onRefreshStrengthChange: (Int) -> Unit,
    onBoldTextChange: (Boolean) -> Unit,
    onFullRefreshEveryNChange: (Int) -> Unit,
    onManualRefresh: () -> Unit,
    onBack: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val active = displayMode == EinkDisplayMode.ON ||
        displayMode == EinkDisplayMode.ON_COLOR ||
        (displayMode == EinkDisplayMode.AUTO && deviceProfile.isEink)
    val statusLabel = when {
        displayMode == EinkDisplayMode.ON -> "Forced on (mono)"
        displayMode == EinkDisplayMode.ON_COLOR -> "Forced on (color)"
        displayMode == EinkDisplayMode.OFF -> "Forced off"
        deviceProfile.isEink -> "Detected ${deviceProfile.vendor.displayName}"
        else -> "Standard display detected"
    }
    val deviceLabel = deviceProfile
        .takeIf { it.isEink }
        ?.let { "${it.manufacturer} ${it.model}".trim().ifBlank { null } }

    SettingsScreenLayout(animatedBackground = dynamicBackgroundEnabled) {
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
                    .padding(
                        horizontal = DS.Spacing.LG.scaled(metrics),
                        vertical = DS.Spacing.SM.scaled(metrics),
                    ),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = onBack)
                Text(
                    text = "E-Ink",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
            }

            SettingsHeroHeader(
                title = "E-Ink Display",
                subtitle = listOfNotNull(statusLabel, deviceLabel).joinToString(" · "),
                badge = if (active) "Active" else "Standby",
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(
                    title = "Display Mode",
                    subtitle = "Auto follows the detected device profile. Mono forces the high-contrast monochrome theme; Color keeps your color theme but still applies E-ink panel optimizations (page-turn refresh, software rendering); Off disables E-ink behavior entirely.",
                )
                EinkSegmentedControlRow(
                    options = listOf("Auto", "Mono", "Color", "Off"),
                    selectedIndex = when (displayMode) {
                        EinkDisplayMode.AUTO -> 0
                        EinkDisplayMode.ON -> 1
                        EinkDisplayMode.ON_COLOR -> 2
                        EinkDisplayMode.OFF -> 3
                    },
                    onSelected = { idx ->
                        onDisplayModeChange(
                            when (idx) {
                                1 -> EinkDisplayMode.ON
                                2 -> EinkDisplayMode.ON_COLOR
                                3 -> EinkDisplayMode.OFF
                                else -> EinkDisplayMode.AUTO
                            },
                        )
                    },
                )
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(
                    title = "Rendering",
                    subtitle = "Tune ghosting and text weight to match the panel.",
                )
                EinkSegmentedControlRow(
                    label = "Page refresh",
                    sublabel = "How aggressively to clear ghosting on page turns. Boox panels can use Light; older Kindles benefit from Strong.",
                    options = listOf("Off", "Light", "Standard", "Strong"),
                    selectedIndex = refreshStrength.coerceIn(0, 3),
                    onSelected = onRefreshStrengthChange,
                    enabled = active,
                )
                HorizontalDivider(color = colors.separator.copy(alpha = 0.3f))
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            horizontal = DS.Spacing.LG.scaled(metrics),
                            vertical = DS.Spacing.MD.scaled(metrics),
                        ),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Bold body text",
                            color = if (active) colors.primaryText else colors.tertiaryText,
                            fontSize = DS.FontSize.Body.scaled(metrics),
                            fontWeight = FontWeight.Medium,
                        )
                        Text(
                            text = "Adds extra weight to body type - looks crisper on lower-DPI panels.",
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                        )
                    }
                    Switch(
                        checked = boldText,
                        onCheckedChange = onBoldTextChange,
                        enabled = active,
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Color.White,
                            checkedTrackColor = colors.accent,
                        ),
                    )
                }
                HorizontalDivider(color = colors.separator.copy(alpha = 0.3f))
                val cadenceOptions = listOf(3, 6, 10, 15)
                EinkSegmentedControlRow(
                    label = "Full refresh cadence",
                    sublabel = "When 'Page refresh' is Standard, a full GC16 clear fires every N page turns. Lower = less ghosting, more flicker. Higher = smoother reading, more drift.",
                    options = cadenceOptions.map { "${it}p" },
                    selectedIndex = cadenceOptions.indexOf(fullRefreshEveryN).coerceAtLeast(0),
                    onSelected = { idx -> onFullRefreshEveryNChange(cadenceOptions[idx.coerceIn(0, cadenceOptions.lastIndex)]) },
                    enabled = active && refreshStrength == 2,
                )
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(
                    title = "Device",
                    subtitle = "Detected hardware and manual controls.",
                )
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            horizontal = DS.Spacing.LG.scaled(metrics),
                            vertical = DS.Spacing.SM.scaled(metrics),
                        ),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = Modifier
                            .size(10.dp)
                            .clip(CircleShape)
                            .background(if (active) Color(0xFF6F8F6A) else colors.tertiaryText),
                    )
                    Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = if (active) "E-Ink mode active" else "E-Ink mode standby",
                            color = colors.primaryText,
                            fontSize = DS.FontSize.Body.scaled(metrics),
                            fontWeight = FontWeight.Medium,
                        )
                        Text(
                            text = listOfNotNull(statusLabel, deviceLabel).joinToString(" · "),
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                        )
                    }
                }
                HorizontalDivider(color = colors.separator.copy(alpha = 0.3f))
                SettingsNavigationRow(
                    icon = Icons.Default.Replay,
                    iconTint = colors.primaryText,
                    title = "Refresh screen now",
                    subtitle = "Force a full GC16 refresh to clear lingering ghost artifacts",
                    enabled = active,
                    onClick = onManualRefresh,
                )
            }

            Spacer(Modifier.height(80.dp.scaled(metrics)))
        }
    }
}

@Composable
private fun EinkSegmentedControlRow(
    options: List<String>,
    selectedIndex: Int,
    onSelected: (Int) -> Unit,
    label: String? = null,
    sublabel: String? = null,
    enabled: Boolean = true,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = DS.Spacing.LG.scaled(metrics),
                vertical = DS.Spacing.MD.scaled(metrics),
            ),
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
    ) {
        if (label != null) {
            Text(
                text = label,
                color = if (enabled) colors.primaryText else colors.tertiaryText,
                fontSize = DS.FontSize.Body.scaled(metrics),
                fontWeight = FontWeight.Medium,
            )
        }
        if (sublabel != null) {
            Text(
                text = sublabel,
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
        }

        val einkActive = EnveTheme.eink.active
        val stripShape = if (einkActive) RoundedCornerShape(2.dp) else RoundedCornerShape(DS.Radius.Pill)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(stripShape)
                .then(
                    if (einkActive) Modifier.border(1.dp, colors.separator, stripShape)
                    else Modifier.background(colors.secondaryBackground)
                )
                .padding(3.dp.scaled(metrics)),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            options.forEachIndexed { index, optionLabel ->
                val isSelected = index == selectedIndex
                val segShape = if (einkActive) RoundedCornerShape(1.dp) else RoundedCornerShape(DS.Radius.Pill)
                val segBg = when {
                    !isSelected -> Color.Transparent
                    einkActive && enabled -> colors.primaryText
                    einkActive -> colors.tertiaryText
                    enabled -> colors.accent.copy(alpha = 0.18f)
                    else -> colors.accent.copy(alpha = 0.08f)
                }
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(segShape)
                        .background(segBg)
                        .clickable(enabled = enabled) { onSelected(index) }
                        .padding(vertical = 8.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = optionLabel,
                        color = when {
                            !enabled -> colors.tertiaryText
                            einkActive && isSelected -> colors.background
                            isSelected -> colors.primaryText
                            else -> colors.secondaryText
                        },
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium,
                    )
                }
            }
        }
    }
}
