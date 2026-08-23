package com.enve.app.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BrightnessMedium
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.SpaceBar
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.data.reader.CustomFont
import com.enve.app.data.reader.MAX_READER_FONT_SCALE
import com.enve.app.data.reader.MIN_READER_FONT_SCALE
import com.enve.app.data.reader.ReaderColumns
import com.enve.app.data.reader.ReaderFont
import com.enve.app.data.reader.ReaderPreferences
import com.enve.app.data.reader.ReaderTheme
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import kotlin.math.roundToInt

private enum class SettingsTab { COLOR, FONT, LAYOUT, OPTIONS }

@Composable
internal fun AppearanceSheet(
    prefs: ReaderPreferences,
    colors: ChromeColors,
    onUpdate: (ReaderPreferences) -> Unit,
    onClose: () -> Unit,
    customFonts: List<CustomFont> = emptyList(),
) {
    var activeTab by remember { mutableStateOf(SettingsTab.FONT) }

    Column(modifier = Modifier.fillMaxWidth().navigationBarsPadding()) {
        if (!EnveTheme.isEink) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(18.dp)
                    .background(
                        Brush.verticalGradient(
                            listOf(
                                Color.Transparent,
                                colors.surface.copy(alpha = 0.55f),
                                colors.surface,
                            ),
                        ),
                    ),
            )
        }

        Box(
            modifier = Modifier
                .align(Alignment.CenterHorizontally)
                .padding(top = 10.dp, bottom = 4.dp)
                .size(width = 36.dp, height = 4.dp)
                .clip(CircleShape)
                .background(Color(0xFF48484A)),
        )

        AnimatedContent(
            targetState = activeTab,
            transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(120)) },
            label = "settingsPanel",
        ) { tab ->
            when (tab) {
                SettingsTab.COLOR   -> ColorPanel(prefs, colors, onUpdate)
                SettingsTab.FONT    -> FontPanel(prefs, colors, onUpdate, customFonts)
                SettingsTab.LAYOUT  -> LayoutPanel(prefs, colors, onUpdate)
                SettingsTab.OPTIONS -> OptionsPanel(prefs, colors, onUpdate)
            }
        }

        HorizontalDivider(color = colors.divider, thickness = 0.5.dp)

        Row(
            modifier = Modifier.fillMaxWidth().background(colors.surface).padding(horizontal = 8.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SettingsTabButton(Icons.Default.Palette,    "Color",   activeTab == SettingsTab.COLOR, colors)   { activeTab = SettingsTab.COLOR }
            SettingsTabButton(Icons.Default.TextFields, "Font",    activeTab == SettingsTab.FONT, colors)    { activeTab = SettingsTab.FONT }
            SettingsTabButton(Icons.Default.SpaceBar,   "Layout",  activeTab == SettingsTab.LAYOUT, colors)  { activeTab = SettingsTab.LAYOUT }
            SettingsTabButton(Icons.Default.Tune,       "Options", activeTab == SettingsTab.OPTIONS, colors) { activeTab = SettingsTab.OPTIONS }
            Spacer(Modifier.width(8.dp))
            Box(
                modifier = Modifier.size(40.dp).clip(CircleShape).background(colors.ghostButtonBg).clickable(onClick = onClose),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Default.Close, "Close", tint = colors.secondaryText, modifier = Modifier.size(18.dp))
            }
        }
    }
}

@Composable private fun SettingsTabButton(icon: ImageVector, label: String, active: Boolean, colors: ChromeColors, onClick: () -> Unit) {
    Column(
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(if (active) colors.accentText.copy(alpha = 0.15f) else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(icon, label, tint = if (active) colors.accentText else colors.secondaryText, modifier = Modifier.size(22.dp))
        Text(label, fontSize = 10.sp, fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal, color = if (active) colors.accentText else colors.secondaryText)
    }
}

@Composable private fun ColorPanel(prefs: ReaderPreferences, colors: ChromeColors, onUpdate: (ReaderPreferences) -> Unit) {
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SheetLabel("Reading Theme", colors)
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ReaderTheme.entries.forEach { theme ->
                val sel = prefs.theme == theme
                Column(
                    modifier = Modifier
                        .weight(1f).clip(RoundedCornerShape(12.dp)).background(theme.previewBg)
                        .then(if (sel) Modifier.border(2.dp, colors.accentText, RoundedCornerShape(12.dp)) else Modifier.border(1.dp, colors.divider, RoundedCornerShape(12.dp)))
                        .clickable { onUpdate(prefs.copy(theme = theme)) }.padding(vertical = 10.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    repeat(3) {
                        Box(modifier = Modifier.fillMaxWidth(0.7f).height(3.dp).clip(CircleShape).background(theme.previewText.copy(alpha = 0.4f)))
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(theme.label, color = theme.previewText, fontSize = 11.sp, fontWeight = if (sel) FontWeight.Bold else FontWeight.Normal)
                }
            }
        }

        Spacer(Modifier.height(4.dp))
        SheetLabel("Reader Dimmer", colors)
        val systemBrightness = prefs.screenBrightness < 0f
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "Darken the page without changing device brightness",
                color = colors.secondaryText,
                fontSize = 12.sp,
            )
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (systemBrightness) colors.ghostButtonBg else colors.accentText.copy(alpha = 0.15f))
                    .padding(horizontal = 9.dp, vertical = 4.dp),
            ) {
                Text(
                    text = if (systemBrightness) "Off" else "${((1f - prefs.screenBrightness) * 100).roundToInt()}%",
                    color = if (systemBrightness) colors.secondaryText else colors.accentText,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                Icons.Default.BrightnessMedium,
                contentDescription = null,
                tint = colors.secondaryText.copy(alpha = 0.65f),
                modifier = Modifier.size(16.dp),
            )
            ThinSlider(
                value = if (systemBrightness) 0.5f else prefs.screenBrightness.coerceIn(0.05f, 1f),
                onValueChange = { onUpdate(prefs.copy(screenBrightness = it)) },
                valueRange = 0.05f..1f,
                accent = colors.accentText,
                modifier = Modifier.weight(1f),
            )
            Icon(
                Icons.Default.BrightnessMedium,
                contentDescription = null,
                tint = colors.secondaryText,
                modifier = Modifier.size(22.dp),
            )
        }
        if (!systemBrightness) {
            TextButton(
                onClick = { onUpdate(prefs.copy(screenBrightness = -1f)) },
                modifier = Modifier.align(Alignment.End),
            ) {
                Text("Turn Dimmer Off", color = colors.accentText)
            }
        }
    }
}

@Composable private fun FontPanel(
    prefs: ReaderPreferences,
    colors: ChromeColors,
    onUpdate: (ReaderPreferences) -> Unit,
    customFonts: List<CustomFont>,
) {
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        SheetLabel("Font Size", colors)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("A", color = colors.secondaryText, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            ThinSlider(
                value = prefs.fontSize, onValueChange = { onUpdate(prefs.copy(fontSize = it)) },
                valueRange = MIN_READER_FONT_SCALE..MAX_READER_FONT_SCALE, modifier = Modifier.weight(1f),
                accent = colors.accentText,
                steps = 32,
            )
            Text("A", color = colors.primaryText, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Text("%.0f%%".format(prefs.fontSize * 100), color = colors.accentText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.widthIn(min = 40.dp))
        }
        SheetLabel("Typeface", colors)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(0.dp)) {

            items(ReaderFont.entries) { font ->
                SheetChip(font.displayName, prefs.font == font && prefs.customFontName == null, colors) {
                    onUpdate(prefs.copy(font = font, customFontName = null))
                }
            }

            items(customFonts) { font ->
                SheetChip(font.displayName, prefs.customFontName == font.displayName, colors) {
                    onUpdate(prefs.copy(customFontName = font.displayName))
                }
            }
        }
    }
}

@Composable private fun LayoutPanel(prefs: ReaderPreferences, colors: ChromeColors, onUpdate: (ReaderPreferences) -> Unit) {
    val scrollState = rememberScrollState()
    Column(modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp).verticalScroll(scrollState).padding(horizontal = 20.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        SheetLabel("Line Height", colors)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ThinSlider(
                value = prefs.lineHeight,
                onValueChange = { onUpdate(prefs.copy(lineHeight = it)) },
                valueRange = 1.0f..2.5f,
                steps = 29,
                modifier = Modifier.weight(1f),
                accent = colors.accentText,
            )
            Text("%.2f".format(prefs.lineHeight), color = colors.accentText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.widthIn(min = 40.dp))
        }
        SheetLabel("Page Margins", colors)
        MarginPickerControl(prefs.pageMargins, prefs.theme, colors) { onUpdate(prefs.copy(pageMargins = it)) }
        SheetLabel("Top / Bottom Margins", colors)
        VerticalMarginPickerControl(prefs.verticalMargins, prefs.theme, colors) { onUpdate(prefs.copy(verticalMargins = it)) }
        SheetLabel("Columns", colors)
        if (prefs.scroll) {
            Text(
                "Columns are disabled in scroll mode.",
                color = colors.secondaryText,
                fontSize = 12.sp,
                modifier = Modifier.padding(bottom = 6.dp),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ReaderColumns.entries.forEach { col ->
                Box(modifier = Modifier.alpha(if (prefs.scroll) 0.45f else 1f)) {
                    SheetChip(col.label, prefs.columns == col, colors) {
                        if (!prefs.scroll) {
                            onUpdate(prefs.copy(columns = col))
                        }
                    }
                }
            }
        }
    }
}

@Composable private fun OptionsPanel(prefs: ReaderPreferences, colors: ChromeColors, onUpdate: (ReaderPreferences) -> Unit) {
    val typographyControlsEnabled = !prefs.publisherStyles
    val scrollState = rememberScrollState()

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 480.dp)
            .verticalScroll(scrollState)
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        SheetLabel("Advanced Text", colors)
        if (!typographyControlsEnabled) {
            Text(
                "Disable Publisher styles to unlock full typography controls.",
                color = colors.secondaryText,
                fontSize = 12.sp,
                modifier = Modifier.padding(bottom = 6.dp),
            )
        }
        SheetLabeledSlider("Word Spacing",      "%.2f".format(prefs.wordSpacing),      prefs.wordSpacing,      0f, 0.5f, colors, enabled = typographyControlsEnabled)  { onUpdate(prefs.copy(wordSpacing = it)) }
        SheetLabeledSlider("Letter Spacing",    "%.2f".format(prefs.letterSpacing),    prefs.letterSpacing,    0f, 0.25f, colors, enabled = typographyControlsEnabled) { onUpdate(prefs.copy(letterSpacing = it)) }
        SheetLabeledSlider("Font Weight",       "%.1f".format(prefs.fontWeight),       prefs.fontWeight,       0.5f, 2.0f, colors, enabled = typographyControlsEnabled){ onUpdate(prefs.copy(fontWeight = it)) }
        SheetLabeledSlider("Paragraph Spacing", "%.1f".format(prefs.paragraphSpacing), prefs.paragraphSpacing, 0f, 2.0f, colors, enabled = typographyControlsEnabled)  { onUpdate(prefs.copy(paragraphSpacing = it)) }
        SheetLabeledSlider("Paragraph Indent",  "%.2f".format(prefs.paragraphIndent),  prefs.paragraphIndent,  0f, 3.0f, colors, enabled = typographyControlsEnabled)  { onUpdate(prefs.copy(paragraphIndent = it)) }

        TextButton(
            enabled = typographyControlsEnabled,
            onClick = {
                onUpdate(
                    prefs.copy(
                        wordSpacing = 0f,
                        letterSpacing = 0f,
                        fontWeight = 1.0f,
                        paragraphSpacing = 0f,
                        paragraphIndent = 0f,
                    )
                )
            },
            modifier = Modifier.align(Alignment.End),
        ) {
            Text("Reset Typography")
        }

        Spacer(Modifier.height(8.dp))
        SheetLabel("Reading Options", colors)
        SheetToggle("Scroll mode",      prefs.scroll, colors)          { onUpdate(prefs.copy(scroll = it)) }
        SheetToggle("Justified text",   prefs.justified, colors, enabled = typographyControlsEnabled)       { onUpdate(prefs.copy(justified = it)) }
        SheetToggle("Publisher styles", prefs.publisherStyles, colors) { onUpdate(prefs.copy(publisherStyles = it)) }
        SheetToggle("Bionic reading",   prefs.bionicReading, colors) { onUpdate(prefs.copy(bionicReading = it)) }
        SheetToggle("Volume button nav", prefs.volumeButtonNavigation, colors) { onUpdate(prefs.copy(volumeButtonNavigation = it)) }

        SheetLabel("Touch Zones", colors)
        LazyRow(
            modifier = Modifier.padding(vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            items(listOf(0.15f, 0.20f, 0.30f)) { width ->
                SheetChip("${(width * 100).roundToInt()}%", kotlin.math.abs(prefs.tapZoneWidth - width) < 0.01f, colors) {
                    onUpdate(prefs.copy(tapZoneWidth = width))
                }
            }
        }
        SheetToggle("Left-edge brightness swipe", prefs.edgeBrightnessSwipe, colors) {
            onUpdate(prefs.copy(edgeBrightnessSwipe = it))
        }

        Spacer(Modifier.height(8.dp))
        SheetLabel("Status Strip", colors)
        SheetToggle("Show clock", prefs.showClock, colors) { onUpdate(prefs.copy(showClock = it)) }
        SheetToggle("Show battery", prefs.showBattery, colors) { onUpdate(prefs.copy(showBattery = it)) }
        SheetLabel("Progress display", colors)
        LazyRow(
            modifier = Modifier.padding(vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            items(com.enve.app.data.reader.ReaderProgressDisplay.entries) { mode ->
                SheetChip(mode.label, prefs.progressDisplay == mode, colors) {
                    onUpdate(prefs.copy(progressDisplay = mode))
                }
            }
        }

        TextButton(
            onClick = {
                onUpdate(
                    prefs.copy(
                        scroll = false,
                        justified = true,
                        publisherStyles = true,
                        volumeButtonNavigation = true,
                        tapZoneWidth = 0.20f,
                        edgeBrightnessSwipe = true,
                    )
                )
            },
            modifier = Modifier.align(Alignment.End),
        ) {
            Text("Reset Reading Options")
        }
    }
}

@Composable internal fun SheetLabel(text: String, colors: ChromeColors) {

    val einkActive = EnveTheme.eink.active
    Text(
        text,
        color = if (einkActive) colors.primaryText else colors.secondaryText,
        fontSize = if (einkActive) 13.sp else 11.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 0.8.sp,
        modifier = Modifier.padding(bottom = 4.dp, top = 4.dp),
    )
}

@Composable internal fun SheetChip(label: String, selected: Boolean, colors: ChromeColors, onClick: () -> Unit) {

    val einkActive = EnveTheme.eink.active
    val shape = if (einkActive) RoundedCornerShape(2.dp) else RoundedCornerShape(8.dp)
    val bg = when {
        selected && einkActive -> colors.primaryText
        selected -> colors.accentText.copy(alpha = 0.18f)
        else -> colors.ghostButtonBg
    }
    Box(
        modifier = Modifier
            .clip(shape)
            .background(bg)
            .then(
                if (selected && !einkActive) Modifier.border(1.dp, colors.accentText, shape)
                else if (!selected && einkActive) Modifier.border(1.dp, colors.primaryText, shape)
                else Modifier
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(
            label,
            color = when {
                selected && einkActive -> colors.background
                selected -> colors.accentText
                else -> colors.secondaryText
            },
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable internal fun SheetLabeledSlider(title: String, valueText: String, value: Float, min: Float, max: Float, colors: ChromeColors, enabled: Boolean = true, onValueChange: (Float) -> Unit) {
    Column(modifier = Modifier.padding(vertical = 4.dp).alpha(if (enabled) 1f else 0.45f)) {
        Row { Text(title, color = colors.primaryText, fontSize = 13.sp, modifier = Modifier.weight(1f)); Text(valueText, color = colors.secondaryText, fontSize = 12.sp) }
        ThinSlider(value = value, onValueChange = { if (enabled) onValueChange(it) }, valueRange = min..max, accent = colors.accentText, enabled = enabled)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ThinSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
    valueRange: ClosedFloatingPointRange<Float> = 0f..1f,
    onValueChangeFinished: (() -> Unit)? = null,
    accent: Color,
    enabled: Boolean = true,
    steps: Int = 0,
) {

    val einkActive = EnveTheme.eink.active
    val trackHeight = if (einkActive) 6.dp else 3.dp
    val thumbSize = if (einkActive) 18.dp else 14.dp
    val trackBackgroundAlpha = if (einkActive) 1f else if (enabled) 0.16f else 0.08f
    val trackFillAlpha = if (enabled) 0.88f else 0.38f
    val trackBgColor = if (einkActive) Color(0xFFCCCCCC) else accent.copy(alpha = trackBackgroundAlpha)
    Slider(
        value = value,
        onValueChange = onValueChange,
        onValueChangeFinished = onValueChangeFinished,
        valueRange = valueRange,
        steps = steps,
        enabled = enabled,
        modifier = modifier,
        thumb = {
            Box(
                Modifier
                    .size(thumbSize)
                    .clip(CircleShape)
                    .background(accent.copy(alpha = if (enabled) 1f else 0.38f))
            )
        },
        track = { state ->
            val r = state.valueRange.endInclusive - state.valueRange.start
            val f = if (r == 0f) 0f else ((state.value - state.valueRange.start) / r).coerceIn(0f, 1f)
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(trackHeight)
                    .clip(RoundedCornerShape(2.dp))
                    .background(trackBgColor)
            ) {
                Box(
                    Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(f)
                        .background(accent.copy(alpha = trackFillAlpha))
                )
            }
        },
    )
}

@Composable internal fun SheetToggle(title: String, value: Boolean, colors: ChromeColors, enabled: Boolean = true, onChanged: (Boolean) -> Unit) {
    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp).alpha(if (enabled) 1f else 0.45f), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = colors.primaryText, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Switch(checked = value, enabled = enabled, onCheckedChange = { if (enabled) onChanged(it) },
            colors = SwitchDefaults.colors(checkedThumbColor = Color.White, checkedTrackColor = colors.accentText))
    }
}

private data class MarginPreset(val label: String, val value: Float)
private val MARGIN_PRESETS = listOf(
    MarginPreset("Narrow", 0.5f),
    MarginPreset("Normal", 1.0f),
    MarginPreset("Wide",   1.5f),
)

@Composable
private fun MarginPickerControl(value: Float, theme: ReaderTheme, colors: ChromeColors, onValueChange: (Float) -> Unit) {
    val pageBg  = theme.previewBg
    val textCol = theme.previewText
    val hPadTarget: Dp = (value / 2f * 28f).dp
    val hPad by animateDpAsState(targetValue = hPadTarget, animationSpec = spring(), label = "marginHPad")
    val pct = (value / 2f * 100f).roundToInt().coerceIn(0, 100)
    Column(modifier = Modifier.padding(vertical = 4.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Page Margins", color = colors.primaryText, fontSize = 13.sp, modifier = Modifier.weight(1f))
            Text("$pct%", color = colors.secondaryText, fontSize = 12.sp)
        }
        Spacer(Modifier.height(8.dp))
        Box(modifier = Modifier.fillMaxWidth().height(64.dp).clip(RoundedCornerShape(8.dp)).background(colors.accentText.copy(alpha = 0.08f)), contentAlignment = Alignment.Center) {
            Box(modifier = Modifier.size(width = 120.dp, height = 50.dp).clip(RoundedCornerShape(4.dp)).background(pageBg)) {
                Column(modifier = Modifier.fillMaxSize().padding(horizontal = hPad, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    repeat(4) { idx -> Box(modifier = Modifier.fillMaxWidth(if (idx == 3) 0.55f else 1f).height(2.dp).clip(RoundedCornerShape(2.dp)).background(textCol.copy(alpha = 0.4f))) }
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            MARGIN_PRESETS.forEach { preset -> SheetChip(preset.label, kotlin.math.abs(value - preset.value) < 0.05f, colors) { onValueChange(preset.value) } }
        }
        ThinSlider(value = value, onValueChange = onValueChange, valueRange = 0f..2.0f, accent = colors.accentText, steps = 39)
    }
}

@Composable
private fun VerticalMarginPickerControl(value: Float, theme: ReaderTheme, colors: ChromeColors, onValueChange: (Float) -> Unit) {
    val pageBg  = theme.previewBg
    val textCol = theme.previewText
    val vPadTarget: Dp = (value / 2f * 14f).dp
    val vPad by animateDpAsState(targetValue = vPadTarget, animationSpec = spring(), label = "marginVPad")
    val pct = (value / 2f * 100f).roundToInt().coerceIn(0, 100)
    Column(modifier = Modifier.padding(vertical = 4.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Top / Bottom Margins", color = colors.primaryText, fontSize = 13.sp, modifier = Modifier.weight(1f))
            Text("$pct%", color = colors.secondaryText, fontSize = 12.sp)
        }
        Spacer(Modifier.height(8.dp))
        Box(modifier = Modifier.fillMaxWidth().height(64.dp).clip(RoundedCornerShape(8.dp)).background(colors.accentText.copy(alpha = 0.08f)), contentAlignment = Alignment.Center) {
            Box(modifier = Modifier.size(width = 120.dp, height = 50.dp).clip(RoundedCornerShape(4.dp)).background(pageBg)) {
                Column(modifier = Modifier.fillMaxSize().padding(horizontal = 8.dp, vertical = vPad), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    repeat(4) { Box(modifier = Modifier.fillMaxWidth().height(2.dp).clip(RoundedCornerShape(2.dp)).background(textCol.copy(alpha = 0.4f))) }
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        ThinSlider(value = value, onValueChange = onValueChange, valueRange = 0f..2.0f, accent = colors.accentText, steps = 39)
    }
}

internal val ReaderTheme.label: String get() = when (this) {
    ReaderTheme.LIGHT -> "Light"
    ReaderTheme.SEPIA -> "Sepia"
    ReaderTheme.DARK  -> "Dark"
    ReaderTheme.OLED  -> "OLED"
}
internal val ReaderTheme.previewBg: Color get() = when (this) {
    ReaderTheme.LIGHT -> Color(0xFFFAFAFA)
    ReaderTheme.SEPIA -> Color(0xFFF3E8D0)
    ReaderTheme.DARK  -> Color(0xFF1E1E1E)
    ReaderTheme.OLED  -> Color(0xFF000000)
}
internal val ReaderTheme.previewText: Color get() = when (this) {
    ReaderTheme.LIGHT, ReaderTheme.SEPIA -> Color(0xFF1A1A1A)
    else -> Color(0xFFE0E0E0)
}
internal val ReaderColumns.label: String get() = when (this) {
    ReaderColumns.AUTO -> "Auto"
    ReaderColumns.ONE  -> "1 Col"
    ReaderColumns.TWO  -> "2 Cols"
}
