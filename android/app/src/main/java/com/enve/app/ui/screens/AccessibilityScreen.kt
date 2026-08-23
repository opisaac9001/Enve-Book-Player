package com.enve.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Animation
import androidx.compose.material.icons.filled.Contrast
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.hearth.design.hearthDisplay
import com.enve.app.ui.theme.AppTheme
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled

@Composable
fun AccessibilityScreen(
    currentTheme: AppTheme,
    dynamicBackgroundEnabled: Boolean,
    onHighContrastChange: (Boolean) -> Unit,
    onReduceMotionChange: (Boolean) -> Unit,
    onBack: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    val highContrastEnabled = currentTheme == AppTheme.EINK
    val reduceMotionEnabled = !dynamicBackgroundEnabled

    SettingsScreenLayout(animatedBackground = dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .verticalScroll(rememberScrollState()),
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
                    text = "Accessibility",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = DS.Spacing.MD.scaled(metrics)),
                )
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(DS.Spacing.LG.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
                ) {
                    Text(
                        text = "Visual accessibility controls",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Body.scaled(metrics),
                    )

                    AccessibilityToggleRow(
                        icon = Icons.Default.Contrast,
                        iconTint = Color(0xFF6F8F6A),
                        title = "High contrast mode",
                        subtitle = "Force the pure black-and-white E-Ink theme. Display mode, refresh strength, and bold text live in Settings → E-Ink Hub.",
                        checked = highContrastEnabled,
                        onCheckedChange = onHighContrastChange,
                    )

                    AccessibilityToggleRow(
                        icon = Icons.Default.Animation,
                        iconTint = Color(0xFF64748B),
                        title = "Reduce motion",
                        subtitle = "Disables the animated background and Hearth screen transitions.",
                        checked = reduceMotionEnabled,
                        onCheckedChange = onReduceMotionChange,
                    )
                }
            }
        }
    }
}

@Composable
private fun AccessibilityToggleRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    iconTint: Color,
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = iconTint)
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = DS.Spacing.MD.scaled(metrics)),
        ) {
            Text(
                text = title,
                color = colors.primaryText,
                fontSize = DS.FontSize.Body.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = subtitle,
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = colors.accent,
            ),
        )
    }
}
