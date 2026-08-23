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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.MicNone
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.ScreenLockPortrait
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.WavingHand
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.hearth.design.hearthDisplay
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled

@Composable
fun PlaybackSettingsScreen(
    onBack: () -> Unit = {},
    dynamicBackgroundEnabled: Boolean = true,
    playbackSpeed: Float = 1.0f,
    skipBackwardSecs: Int = 30,
    skipForwardSecs: Int = 30,
    voiceBoost: Boolean = false,
    keepScreenOn: Boolean = true,
    continuousPlayback: Boolean = true,
    autoPlayNextInSeries: Boolean = false,
    volumeBoost: Boolean = false,
    sleepTimerActive: Boolean = false,
    sleepMinutes: Int = 30,
    onPlaybackSpeedChange: (Float) -> Unit = {},
    onSkipBackwardChange: (Int) -> Unit = {},
    onSkipForwardChange: (Int) -> Unit = {},
    onVoiceBoostChange: (Boolean) -> Unit = {},
    onKeepScreenOnChange: (Boolean) -> Unit = {},
    onContinuousPlaybackChange: (Boolean) -> Unit = {},
    onAutoPlayNextInSeriesChange: (Boolean) -> Unit = {},
    onVolumeBoostChange: (Boolean) -> Unit = {},
    onSleepTimerChange: (Int?) -> Unit = {},
    sleepTimerFadeEnabled: Boolean = true,
    onSleepTimerFadeChange: (Boolean) -> Unit = {},
    onNavigateToAudioEffects: () -> Unit = {},
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    val speedOptions = listOf(0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f, 2.5f, 2.75f, 3.0f)
    val skipOptions = listOf(10, 15, 30, 45, 60, 90, 120)

    val dividerColor = colors.separator.copy(alpha = 0.5f)

    SettingsScreenLayout(animatedBackground = dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(bottom = 80.dp),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = onBack)
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = DS.Spacing.MD.scaled(metrics)),
                ) {
                    Text(
                        text = "Playback",
                        color = colors.primaryText,
                        style = hearthDisplay(22.sp),
                    )
                    Text(
                        text = "Speed, skips, and controls",
                        color = colors.secondaryText,
                        fontSize = 12.sp,
                    )
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics))) {
                    PlaybackSectionLabel(
                        icon = Icons.Default.Speed,
                        tint = colors.accent,
                        title = "Playback Speed",
                        subtitle = "Current: ${if (playbackSpeed == playbackSpeed.toLong().toFloat()) "${playbackSpeed.toInt()}×" else "${playbackSpeed}×"}",
                    )
                    Spacer(Modifier.height(DS.Spacing.LG.scaled(metrics)))

                    val rows = speedOptions.chunked(5)
                    rows.forEach { row ->
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                        ) {
                            row.forEach { speed ->
                                val selected = playbackSpeed == speed
                                val label = if (speed == speed.toLong().toFloat()) "${speed.toInt()}×" else "${speed}×"
                                Box(
                                    modifier = Modifier
                                        .weight(1f)
                                        .heightIn(min = 40.dp)
                                        .clip(RoundedCornerShape(12.dp))
                                        .background(
                                            if (selected) colors.accent else colors.secondaryBackground,
                                        )
                                        .border(
                                            width = if (selected) 0.dp else 0.5.dp,
                                            color = colors.separator,
                                            shape = RoundedCornerShape(12.dp),
                                        )
                                        .clickable { onPlaybackSpeedChange(speed) },
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(
                                        text = label,
                                        color = if (selected) colors.onAccent else colors.primaryText,
                                        fontSize = 13.sp,
                                        fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                                        modifier = Modifier.padding(vertical = 6.dp),
                                    )
                                }
                            }
                            if (row.size < 5) {
                                repeat(5 - row.size) { Spacer(Modifier.weight(1f)) }
                            }
                        }
                        Spacer(Modifier.height(DS.Spacing.SM.scaled(metrics)))
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics))) {
                    PlaybackSectionLabel(
                        icon = Icons.Default.FastRewind,
                        tint = Color(0xFF64748B),
                        title = "Skip Intervals",
                        subtitle = "Tap the rewind/forward buttons",
                    )
                    Spacer(Modifier.height(DS.Spacing.LG.scaled(metrics)))

                    SkipIntervalRow(
                        label = "Skip backward",
                        value = skipBackwardSecs,
                        options = skipOptions,
                        unit = "s",
                        onValueChange = onSkipBackwardChange,
                        icon = Icons.Default.FastRewind,
                        tint = Color(0xFF64748B),
                    )
                    Spacer(Modifier.height(DS.Spacing.MD.scaled(metrics)))
                    HorizontalDivider(color = dividerColor)
                    Spacer(Modifier.height(DS.Spacing.MD.scaled(metrics)))
                    SkipIntervalRow(
                        label = "Skip forward",
                        value = skipForwardSecs,
                        options = skipOptions,
                        unit = "s",
                        onValueChange = onSkipForwardChange,
                        icon = Icons.Default.FastForward,
                        tint = Color(0xFFA05252),
                    )
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                PlaybackToggleRow(
                    icon = Icons.Default.MicNone,
                    tint = Color(0xFF6F8F6A),
                    title = "Voice Boost",
                    subtitle = "EQ filter to enhance spoken-word clarity",
                    checked = voiceBoost,
                    onCheckedChange = onVoiceBoostChange,
                )
                HorizontalDivider(color = dividerColor)
                PlaybackToggleRow(
                    icon = Icons.AutoMirrored.Filled.VolumeUp,
                    tint = Color(0xFFF5921A),
                    title = "Volume Boost",
                    subtitle = "Amplify quiet recordings",
                    checked = volumeBoost,
                    onCheckedChange = onVolumeBoostChange,
                )
                HorizontalDivider(color = dividerColor)
                PlaybackToggleRow(
                    icon = Icons.Default.ScreenLockPortrait,
                    tint = Color(0xFF64748B),
                    title = "Keep Screen On",
                    subtitle = "Prevent sleep while audio is playing",
                    checked = keepScreenOn,
                    onCheckedChange = onKeepScreenOnChange,
                )
                HorizontalDivider(color = dividerColor)
                PlaybackToggleRow(
                    icon = Icons.Default.GraphicEq,
                    tint = Color(0xFFA05252),
                    title = "Continuous Playback",
                    subtitle = "Auto-advance to next book on completion",
                    checked = continuousPlayback,
                    onCheckedChange = onContinuousPlaybackChange,
                )
                HorizontalDivider(color = dividerColor)
                PlaybackToggleRow(
                    icon = Icons.Default.SkipNext,
                    tint = Color(0xFFA05252),
                    title = "Play Next in Series",
                    subtitle = "Continue with the next unfinished book when Up Next is empty",
                    checked = autoPlayNextInSeries,
                    onCheckedChange = onAutoPlayNextInSeriesChange,
                    enabled = continuousPlayback,
                )
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics))) {
                    PlaybackToggleRow(
                        icon = Icons.Default.Bedtime,
                        tint = Color(0xFF64748B),
                        title = "Sleep Timer",
                        subtitle = "Automatically pause after a set time",
                        checked = sleepTimerActive,
                        onCheckedChange = {
                            if (it) onSleepTimerChange(sleepMinutes) else onSleepTimerChange(null)
                        },
                        rowPadding = false,
                    )
                    if (sleepTimerActive) {
                        Spacer(Modifier.height(DS.Spacing.LG.scaled(metrics)))
                        HorizontalDivider(color = dividerColor)
                        Spacer(Modifier.height(DS.Spacing.LG.scaled(metrics)))

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                        ) {
                            IconButton(
                                onClick = { if (sleepMinutes > 5) onSleepTimerChange(sleepMinutes - 5) },
                                modifier = Modifier
                                    .size(44.dp)
                                    .background(colors.secondaryBackground, CircleShape),
                            ) {
                                Icon(Icons.Default.Remove, null, tint = colors.primaryText)
                            }

                            Column(
                                modifier = Modifier.weight(1f),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                Text(
                                    text = "$sleepMinutes",
                                    color = colors.accent,
                                    fontSize = 40.sp,
                                    fontWeight = FontWeight.Black,
                                )
                                Text(
                                    text = "minutes",
                                    color = colors.secondaryText,
                                    fontSize = 13.sp,
                                )
                            }

                            IconButton(
                                onClick = { if (sleepMinutes < 120) onSleepTimerChange(sleepMinutes + 5) },
                                modifier = Modifier
                                    .size(44.dp)
                                    .background(colors.secondaryBackground, CircleShape),
                            ) {
                                Icon(Icons.Default.Add, null, tint = colors.primaryText)
                            }
                        }

                        Spacer(Modifier.height(DS.Spacing.LG.scaled(metrics)))

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                        ) {
                            listOf(15, 30, 45, 60, 90).forEach { preset ->
                                val selected = sleepMinutes == preset
                                Box(
                                    modifier = Modifier
                                        .weight(1f)
                                        .heightIn(min = 36.dp)
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(if (selected) colors.accent else colors.secondaryBackground)
                                        .clickable { onSleepTimerChange(preset) },
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(
                                        text = "${preset}m",
                                        color = if (selected) colors.onAccent else colors.secondaryText,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        modifier = Modifier.padding(vertical = 6.dp),
                                    )
                                }
                            }
                        }
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                PlaybackToggleRow(
                    icon = Icons.Default.WavingHand,
                    tint = Color(0xFFA05252),
                    title = "Sleep Timer Fade",
                    subtitle = "Gradually lower volume before pausing",
                    checked = sleepTimerFadeEnabled,
                    onCheckedChange = onSleepTimerFadeChange,
                )
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(onClick = onNavigateToAudioEffects)
                        .padding(DS.Spacing.LG.scaled(metrics)),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = Modifier
                            .size(40.dp)
                            .background(Color(0xFF6F8F6A).copy(alpha = 0.14f), CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Default.GraphicEq, null, tint = Color(0xFF6F8F6A), modifier = Modifier.size(20.dp))
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Audio Effects", color = colors.primaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                        Text("Equalizer, volume boost, and bass boost", color = colors.secondaryText, fontSize = 12.sp)
                    }
                    Icon(Icons.Default.ChevronRight, null, tint = colors.tertiaryText)
                }
            }
        }
    }
}

@Composable
private fun PlaybackSectionLabel(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
) {
    val colors = EnveTheme.colors

    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .background(tint.copy(alpha = 0.14f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(12.dp))
        Column {
            Text(title, color = colors.primaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text(subtitle, color = colors.secondaryText, fontSize = 12.sp)
        }
    }
}

@Composable
private fun SkipIntervalRow(
    label: String,
    value: Int,
    options: List<Int>,
    unit: String,
    onValueChange: (Int) -> Unit,
    icon: ImageVector,
    tint: Color,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .background(tint.copy(alpha = 0.14f), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, null, tint = tint, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(12.dp))
            Text(label, color = colors.primaryText, fontSize = 14.sp, modifier = Modifier.weight(1f))
            Text(
                text = "$value$unit",
                color = colors.secondaryText,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(colors.secondaryBackground, RoundedCornerShape(999.dp))
                .padding(4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            options.forEach { opt ->
                val selected = value == opt
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = 34.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(if (selected) Color.White.copy(alpha = 0.42f) else Color.Transparent)
                        .clickable { onValueChange(opt) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "$opt$unit",
                        color = if (selected) colors.primaryText else colors.secondaryText,
                        fontSize = 11.sp,
                        fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                        modifier = Modifier.padding(vertical = 6.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun PlaybackToggleRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    rowPadding: Boolean = true,
    enabled: Boolean = true,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .alpha(if (enabled) 1f else 0.5f)
            .then(if (rowPadding) Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)) else Modifier),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .background(tint.copy(alpha = 0.14f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = colors.primaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Text(subtitle, color = colors.secondaryText, fontSize = 12.sp)
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            enabled = enabled,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = colors.accent,
            ),
        )
    }
}
