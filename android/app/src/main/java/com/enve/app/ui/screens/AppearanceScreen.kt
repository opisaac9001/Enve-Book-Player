package com.enve.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Contrast
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Square
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material3.Slider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.toArgb
import android.graphics.Color as AndroidColor
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.ui.components.ScreenBackButton
import com.enve.hearth.design.hearthDisplay
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.theme.AppTheme
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import kotlin.math.abs

@Composable
fun AppearanceScreen(
    currentTheme: AppTheme,
    currentColor: Color,
    dynamicBackgroundEnabled: Boolean,
    onThemeChange: (AppTheme) -> Unit,
    onColorChange: (Color) -> Unit,
    onDynamicBackgroundChange: (Boolean) -> Unit,
    onBack: () -> Unit,
    onNavigateToEinkHub: () -> Unit = {},
    onNavigateToCustomFonts: () -> Unit = {},
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    val presetColors = listOf(
        Color(0xFF2A0003),
        Color(0xFFE89B05),
        Color(0xFFFF2E33),
        Color(0xFFF24693),
        Color(0xFFB347E6),
        Color(0xFF3D91E6),
        Color(0xFF3EC2D9),
        Color(0xFF4DD861),
        Color(0xFFEED810),
    )

    SettingsScreenLayout(animatedBackground = dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(bottom = DS.Spacing.XXXL.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = onBack)
                Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
                Column {
                    Text(
                        text = "Appearance",
                        color = colors.primaryText,
                        style = hearthDisplay(22.sp),
                    )
                    Text(
                        text = "Custom color and visual effects",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(DS.Spacing.LG.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                ) {
                    CardOverline("Custom Color")
                    HsvColorPicker(currentColor = currentColor, onColorChange = onColorChange)

                    Spacer(Modifier.height(DS.Spacing.SM.scaled(metrics)))

                    CardOverline("Preset Colors")

                    listOf(
                        presetColors.take(4),
                        presetColors.drop(4).take(4),
                        presetColors.takeLast(1),
                    ).forEach { row ->
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                        ) {
                            row.forEach { color ->
                                val isSelected = currentColor == color ||
                                    abs(currentColor.red - color.red) < 0.05f &&
                                    abs(currentColor.green - color.green) < 0.05f &&
                                    abs(currentColor.blue - color.blue) < 0.05f

                                Box(
                                    modifier = Modifier
                                        .weight(1f)
                                        .height(if (row.size == 1) 74.dp else 62.dp)
                                        .background(color, RoundedCornerShape(16.dp))
                                        .clickable { onColorChange(color) },
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (isSelected) {
                                        Box(
                                            modifier = Modifier
                                                .size(36.dp)
                                                .background(Color.White.copy(alpha = 0.9f), CircleShape),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Icon(Icons.Default.Check, contentDescription = "Selected", tint = colors.accent)
                                        }
                                    }
                                }
                            }

                            if (row.size == 1) {
                                Spacer(Modifier.weight(1f))
                                Spacer(Modifier.weight(1f))
                                Spacer(Modifier.weight(1f))
                            }
                        }
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(DS.Spacing.LG.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                ) {
                    CardOverline("Background Effects")
                    Text("Control the animated glow background used across the app", color = colors.secondaryText, fontSize = 13.sp)

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            modifier = Modifier
                                .size(40.dp)
                                .background(colors.accent.copy(alpha = 0.16f), CircleShape),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = colors.accent)
                        }
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Dynamic Background", color = colors.primaryText, fontSize = DS.FontSize.Title3.scaled(metrics), fontWeight = FontWeight.Bold)
                            Text("Turn off animated background motion for a flatter look", color = colors.secondaryText, fontSize = DS.FontSize.Body.scaled(metrics))
                        }
                        Switch(
                            checked = dynamicBackgroundEnabled,
                            onCheckedChange = onDynamicBackgroundChange,
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = Color.White,
                                checkedTrackColor = colors.accent,
                            ),
                        )
                    }
                }
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics)),
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
            ) {
                ThemeChip(currentTheme == AppTheme.LIGHT, "Light") { onThemeChange(AppTheme.LIGHT) }
                ThemeChip(currentTheme == AppTheme.DARK, "Dark") { onThemeChange(AppTheme.DARK) }
                ThemeChip(currentTheme == AppTheme.PAPER_WHITE, "Paper") { onThemeChange(AppTheme.PAPER_WHITE) }
                ThemeChip(currentTheme == AppTheme.EINK, "E-Ink") { onThemeChange(AppTheme.EINK) }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(DS.Spacing.LG.scaled(metrics)),
                ) {
                    CardOverline("E-Ink")
                    Text("Refresh strategy, bold body text, and panel detection", color = colors.secondaryText, fontSize = 13.sp)

                    Spacer(Modifier.height(DS.Spacing.MD.scaled(metrics)))

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(onClick = onNavigateToEinkHub),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            modifier = Modifier
                                .size(40.dp)
                                .background(colors.accent.copy(alpha = 0.16f), CircleShape),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Default.Contrast, contentDescription = null, tint = colors.accent)
                        }
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text("E-Ink Hub", color = colors.primaryText, fontSize = DS.FontSize.Title3.scaled(metrics), fontWeight = FontWeight.SemiBold)
                            Text("Display mode, refresh strength, and bold text", color = colors.secondaryText, fontSize = 13.sp)
                        }
                        Icon(Icons.Default.ChevronRight, contentDescription = null, tint = colors.tertiaryText)
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(DS.Spacing.LG.scaled(metrics)),
                ) {
                    CardOverline("Reader")
                    Text("Custom typefaces for ebook reading", color = colors.secondaryText, fontSize = 13.sp)

                    Spacer(Modifier.height(DS.Spacing.MD.scaled(metrics)))

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(onClick = onNavigateToCustomFonts),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            modifier = Modifier
                                .size(40.dp)
                                .background(colors.accent.copy(alpha = 0.16f), CircleShape),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Default.TextFields, contentDescription = null, tint = colors.accent)
                        }
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Custom Fonts", color = colors.primaryText, fontSize = DS.FontSize.Title3.scaled(metrics), fontWeight = FontWeight.SemiBold)
                            Text("Upload TTF or OTF files to use any typeface", color = colors.secondaryText, fontSize = 13.sp)
                        }
                        Icon(Icons.Default.ChevronRight, contentDescription = null, tint = colors.tertiaryText)
                    }
                }
            }
        }
    }
}

@Composable
private fun CardOverline(text: String) {
    Text(
        text = text.uppercase(),
        color = EnveTheme.colors.tertiaryText,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 1.6.sp,
    )
}
@Composable
private fun HsvColorPicker(
    currentColor: Color,
    onColorChange: (Color) -> Unit,
) {
    var hue by remember { mutableFloatStateOf(0f) }
    var sat by remember { mutableFloatStateOf(0f) }
    var value by remember { mutableFloatStateOf(0f) }

    var lastEmittedArgb by remember { mutableStateOf<Int?>(null) }
    val incomingArgb = currentColor.toArgb()
    LaunchedEffect(incomingArgb) {
        if (incomingArgb != lastEmittedArgb) {
            val hsv = FloatArray(3)
            AndroidColor.colorToHSV(incomingArgb, hsv)
            hue = hsv[0]
            sat = hsv[1].coerceAtLeast(0.4f)
            value = hsv[2].coerceAtLeast(0.4f)
            lastEmittedArgb = incomingArgb
        }
    }

    fun emit() {
        val out = Color(AndroidColor.HSVToColor(floatArrayOf(hue, sat, value)))
        lastEmittedArgb = out.toArgb()
        onColorChange(out)
    }

    val preview = Color(AndroidColor.HSVToColor(floatArrayOf(hue, sat, value)))

    val rainbow = listOf(
        Color(0xFFFF0000), Color(0xFFFFFF00), Color(0xFF00FF00),
        Color(0xFF00FFFF), Color(0xFF0000FF), Color(0xFFFF00FF), Color(0xFFFF0000),
    )

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(36.dp)
                .background(preview, RoundedCornerShape(10.dp)),
        )

        Text("Hue", color = EnveTheme.colors.secondaryText, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(28.dp)
                .background(Brush.horizontalGradient(rainbow), RoundedCornerShape(8.dp)),
        ) {
            Slider(
                value = hue,
                onValueChange = { hue = it; emit() },
                valueRange = 0f..360f,
                modifier = Modifier.fillMaxSize(),
            )
        }

        Text("Saturation", color = EnveTheme.colors.secondaryText, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        Slider(
            value = sat,
            onValueChange = { sat = it; emit() },
            valueRange = 0f..1f,
        )

        Text("Brightness", color = EnveTheme.colors.secondaryText, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        Slider(
            value = value,
            onValueChange = { value = it; emit() },
            valueRange = 0f..1f,
        )
    }
}

@Composable
private fun ThemeChip(
    selected: Boolean,
    label: String,
    onClick: () -> Unit,
) {
    val colors = EnveTheme.colors
    Box(
        modifier = Modifier
            .widthIn(min = 72.dp)
            .background(
                if (selected) colors.accent.copy(alpha = 0.16f) else colors.cardBackground,
                RoundedCornerShape(999.dp),
            )
            .border(0.5.dp, colors.separator.copy(alpha = 0.6f), RoundedCornerShape(999.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            color = if (selected) colors.accent else colors.secondaryText,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}
