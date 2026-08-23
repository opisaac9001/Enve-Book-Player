package com.enve.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BrightnessMedium
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.viewmodel.ComicBackgroundTheme
import com.enve.app.viewmodel.ComicPageFit
import com.enve.app.viewmodel.ComicProgressionMode
import com.enve.app.viewmodel.ComicReaderSettings
import com.enve.app.viewmodel.ComicReadingDirection
import com.enve.app.viewmodel.ComicSpreadMode
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ComicSettingsSheet(
    settings: ComicReaderSettings,
    onSettingsChange: (ComicReaderSettings) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val accent = MaterialTheme.colorScheme.primary
    val sheetBg = Color(0xFF0D0D10)
    val cardBg = Color(0xFF1A1A1F)
    val cardBorder = Color.White.copy(alpha = 0.07f)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = sheetBg,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        dragHandle = {
            Box(
                modifier = Modifier
                    .padding(top = 12.dp, bottom = 4.dp)
                    .size(width = 40.dp, height = 4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(Color.White.copy(alpha = 0.20f)),
            )
        },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp)
                .padding(bottom = 44.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 4.dp, bottom = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column {
                    Text("READER", color = Color.White.copy(alpha = 0.32f), fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.8.sp)
                    Text("Settings", color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.Bold)
                }
                Box(
                    modifier = Modifier
                        .size(38.dp)
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = 0.08f))
                        .clickable(onClick = onDismiss),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White.copy(alpha = 0.60f), modifier = Modifier.size(18.dp))
                }
            }

            SettingsCard(bg = cardBg, border = cardBorder) {
                SettingsCardSection(label = "Reading Mode") {
                    PillRow(
                        options = ComicProgressionMode.entries.map { it.label },
                        selectedIndex = settings.progressionMode.ordinal,
                        accent = accent,
                        onSelect = { onSettingsChange(settings.copy(progressionMode = ComicProgressionMode.entries[it])) },
                    )
                }
                Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(cardBorder))
                SettingsCardSection(label = "Direction") {
                    PillRow(
                        options = ComicReadingDirection.entries.map { it.label },
                        selectedIndex = settings.readingDirection.ordinal,
                        accent = accent,
                        onSelect = { onSettingsChange(settings.copy(readingDirection = ComicReadingDirection.entries[it])) },
                    )
                }
            }

            SettingsCard(bg = cardBg, border = cardBorder) {
                SettingsCardSection(label = "Page Fit") {
                    PillRow(
                        options = ComicPageFit.entries.map { it.label },
                        selectedIndex = settings.pageFit.ordinal,
                        accent = accent,
                        onSelect = { onSettingsChange(settings.copy(pageFit = ComicPageFit.entries[it])) },
                    )
                }
                Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(cardBorder))
                SettingsCardSection(label = "Spread Pages") {
                    PillRow(
                        options = ComicSpreadMode.entries.map { it.label },
                        selectedIndex = settings.spreadMode.ordinal,
                        accent = accent,
                        onSelect = { onSettingsChange(settings.copy(spreadMode = ComicSpreadMode.entries[it])) },
                    )
                }
            }

            SettingsCard(bg = cardBg, border = cardBorder) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Text("Background", color = Color.White.copy(alpha = 0.45f), fontSize = 12.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.5.sp)
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                    ) {
                        ComicBackgroundTheme.entries.forEach { theme ->
                            val sel = settings.backgroundTheme == theme
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(6.dp),
                                modifier = Modifier.clickable { onSettingsChange(settings.copy(backgroundTheme = theme)) },
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(44.dp)
                                        .clip(CircleShape)
                                        .background(Color(theme.argb))
                                        .border(
                                            width = if (sel) 2.5.dp else 1.dp,
                                            color = if (sel) accent else Color.White.copy(alpha = 0.14f),
                                            shape = CircleShape,
                                        ),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (sel) {
                                        Icon(
                                            Icons.Default.Check,
                                            contentDescription = null,
                                            tint = if (theme == ComicBackgroundTheme.WHITE) Color.Black else Color.White,
                                            modifier = Modifier.size(20.dp),
                                        )
                                    }
                                }
                                Text(
                                    theme.label,
                                    color = if (sel) accent else Color.White.copy(alpha = 0.35f),
                                    fontSize = 10.sp,
                                    fontWeight = if (sel) FontWeight.SemiBold else FontWeight.Normal,
                                )
                            }
                        }
                    }
                }
            }

            SettingsCard(bg = cardBg, border = cardBorder) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("Brightness", color = Color.White.copy(alpha = 0.45f), fontSize = 12.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.5.sp)
                        val isSystem = settings.brightness < 0f
                        Surface(
                            shape = RoundedCornerShape(8.dp),
                            color = if (isSystem) Color.White.copy(alpha = 0.06f) else accent.copy(alpha = 0.16f),
                        ) {
                            Text(
                                text = if (isSystem) "System" else "${(settings.brightness * 100).roundToInt()}%",
                                color = if (isSystem) Color.White.copy(alpha = 0.36f) else accent,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp),
                            )
                        }
                    }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(Icons.Default.BrightnessMedium, contentDescription = null, tint = Color.White.copy(alpha = 0.22f), modifier = Modifier.size(16.dp))
                        ThinSlider(
                            value = if (settings.brightness < 0f) 0.5f else settings.brightness,
                            onValueChange = { onSettingsChange(settings.copy(brightness = it)) },
                            valueRange = 0.05f..1f,
                            modifier = Modifier.weight(1f),
                            accent = accent,
                        )
                        Icon(Icons.Default.BrightnessMedium, contentDescription = null, tint = Color.White.copy(alpha = 0.70f), modifier = Modifier.size(22.dp))
                    }
                    if (settings.brightness >= 0f) {
                        Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                            Text(
                                "Use system brightness",
                                color = accent,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(8.dp))
                                    .clickable { onSettingsChange(settings.copy(brightness = -1f)) }
                                    .padding(horizontal = 6.dp, vertical = 4.dp),
                            )
                        }
                    }
                }
            }

            SettingsCard(bg = cardBg, border = cardBorder) {
                ToggleCardRow(
                    label = "Zoom & Pan",
                    sublabel = "Pinch to zoom and pan pages",
                    checked = settings.zoomEnabled,
                    accent = accent,
                    onToggle = { onSettingsChange(settings.copy(zoomEnabled = it)) },
                )
                Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(cardBorder))
                ToggleCardRow(
                    label = "Auto-hide Controls",
                    sublabel = "Hide controls while reading",
                    checked = settings.autoHideChrome,
                    accent = accent,
                    onToggle = { onSettingsChange(settings.copy(autoHideChrome = it)) },
                )
                Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(cardBorder))
                ToggleCardRow(
                    label = "Volume Navigation",
                    sublabel = "Turn pages with volume buttons",
                    checked = settings.volumeButtonNavigation,
                    accent = accent,
                    onToggle = { onSettingsChange(settings.copy(volumeButtonNavigation = it)) },
                )
            }
        }
    }
}

@Composable
private fun SettingsCard(
    bg: Color,
    border: Color,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(bg)
            .border(1.dp, border, RoundedCornerShape(16.dp)),
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            content()
        }
    }
}

@Composable
private fun SettingsCardSection(
    label: String,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(label, color = Color.White.copy(alpha = 0.45f), fontSize = 12.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.5.sp)
        content()
    }
}

@Composable
private fun PillRow(
    options: List<String>,
    selectedIndex: Int,
    accent: Color,
    onSelect: (Int) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        options.forEachIndexed { idx, label ->
            val selected = idx == selectedIndex
            Box(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 36.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (selected) accent.copy(alpha = 0.18f) else Color.White.copy(alpha = 0.05f))
                    .border(
                        width = if (selected) 1.dp else 0.dp,
                        color = if (selected) accent.copy(alpha = 0.75f) else Color.Transparent,
                        shape = RoundedCornerShape(10.dp),
                    )
                    .clickable { onSelect(idx) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label,
                    color = if (selected) accent else Color.White.copy(alpha = 0.48f),
                    fontSize = 13.sp,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp),
                )
            }
        }
    }
}

@Composable
private fun ToggleCardRow(
    label: String,
    sublabel: String,
    checked: Boolean,
    accent: Color,
    onToggle: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onToggle(!checked) }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Column(modifier = Modifier.weight(1f).padding(end = 16.dp)) {
            Text(label, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(sublabel, color = Color.White.copy(alpha = 0.32f), fontSize = 12.sp)
        }
        Switch(
            checked = checked,
            onCheckedChange = onToggle,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = accent,
                uncheckedThumbColor = Color.White.copy(alpha = 0.55f),
                uncheckedTrackColor = Color.White.copy(alpha = 0.12f),
                uncheckedBorderColor = Color.Transparent,
                checkedBorderColor = Color.Transparent,
            ),
        )
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
) {
    Slider(
        value = value,
        onValueChange = onValueChange,
        onValueChangeFinished = onValueChangeFinished,
        valueRange = valueRange,
        enabled = enabled,
        modifier = modifier,
        thumb = {
            Box(
                Modifier
                    .size(14.dp)
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
                    .height(3.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(accent.copy(alpha = if (enabled) 0.16f else 0.08f))
            ) {
                Box(
                    Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(f)
                        .background(accent.copy(alpha = if (enabled) 0.88f else 0.38f))
                )
            }
        },
    )
}
