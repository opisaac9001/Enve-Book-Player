package com.enve.app.ui.screens

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Equalizer
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.playback.AudioEffectsManager
import com.enve.app.playback.EqPreset
import com.enve.app.playback.EqualizerState
import com.enve.app.ui.components.ChromeActionButton
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.theme.DS
import com.enve.hearth.design.hearthDisplay
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.PlayerViewModel
import com.enve.core.data.model.VolumeLevelingStrength
import java.util.Locale

@Composable
fun AudioEffectsScreen(
    viewModel: PlayerViewModel,
    dynamicBackgroundEnabled: Boolean = true,
    onBack: () -> Unit = {},
) {
    val eqState by viewModel.eqState.collectAsState()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.5f)
    val equalizerConfigurable = !eqState.audioSessionActive || eqState.equalizerSupported
    val volumeBoostConfigurable = !eqState.audioSessionActive || eqState.volumeBoostSupported
    val volumeLevelingConfigurable = !eqState.audioSessionActive || eqState.volumeLevelingSupported
    val bassBoostConfigurable = !eqState.audioSessionActive || eqState.bassBoostSupported

    SettingsScreenLayout(animatedBackground = dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .verticalScroll(rememberScrollState()),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = onBack)
                Text(
                    text = "Audio Effects",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = DS.Spacing.MD.scaled(metrics)),
                )
                ChromeActionButton(
                    onClick = { viewModel.resetAudioEffects() },
                    icon = Icons.Default.Refresh,
                    contentDescription = "Reset",
                )
            }

            Spacer(Modifier.height(DS.Spacing.MD.scaled(metrics)))

            EffectsSectionLabel(
                icon = Icons.Default.GraphicEq,
                tint = Color(0xFF6F8F6A),
                title = "Equalizer",
                subtitle = "Fine-tune audio frequencies",
            )

            Spacer(Modifier.height(DS.Spacing.SM.scaled(metrics)))

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics))) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("Equalizer", color = colors.primaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                        Switch(
                            checked = eqState.eqEnabled && equalizerConfigurable,
                            onCheckedChange = { viewModel.setEqEnabled(it) },
                            enabled = equalizerConfigurable,
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = Color.White,
                                checkedTrackColor = colors.accent,
                            ),
                        )
                    }

                    if (eqState.eqEnabled) {
                        Spacer(Modifier.height(DS.Spacing.MD.scaled(metrics)))

                        LazyRow(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            contentPadding = PaddingValues(horizontal = 0.dp),
                        ) {
                            items(EqPreset.entries.filter { it != EqPreset.CUSTOM }) { preset ->
                                PresetChip(
                                    label = preset.displayName,
                                    selected = eqState.preset == preset,
                                    accentColor = colors.accent,
                                    onClick = { viewModel.setEqPreset(preset) },
                                )
                            }
                            if (eqState.preset == EqPreset.CUSTOM) {
                                item {
                                    PresetChip(
                                        label = "Custom",
                                        selected = true,
                                        accentColor = colors.accent,
                                        onClick = {},
                                    )
                                }
                            }
                        }

                        Spacer(Modifier.height(DS.Spacing.LG.scaled(metrics)))

                        if (eqState.numberOfBands > 0) {
                            EqualizerBands(
                                state = eqState,
                                accentColor = colors.accent,
                                onBandChange = { band, level -> viewModel.setEqBandLevel(band, level) },
                            )
                        } else {
                            Text(
                                text = when {
                                    !eqState.audioSessionActive -> "Start playback to attach an audio session and load EQ bands."
                                    !eqState.equalizerSupported -> "Equalizer is not supported by this device or audio session."
                                    else -> "Equalizer bands are not available for this session."
                                },
                                color = colors.tertiaryText,
                                fontSize = 13.sp,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.fillMaxWidth().padding(vertical = DS.Spacing.LG),
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(DS.Spacing.XL.scaled(metrics)))

            EffectsSectionLabel(
                icon = Icons.Default.Equalizer,
                tint = Color(0xFF8A72C4),
                title = "Volume Leveling",
                subtitle = "Even out loud and quiet passages",
            )

            Spacer(Modifier.height(DS.Spacing.SM.scaled(metrics)))

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics))) {
                    Text(
                        text = "Choose how strongly Enve compresses the recording's dynamic range.",
                        color = colors.secondaryText,
                        fontSize = 13.sp,
                    )

                    Spacer(Modifier.height(DS.Spacing.MD.scaled(metrics)))

                    LazyRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        contentPadding = PaddingValues(horizontal = 0.dp),
                    ) {
                        items(VolumeLevelingStrength.entries) { strength ->
                            PresetChip(
                                label = strength.displayName,
                                selected = eqState.volumeLevelingStrength == strength,
                                accentColor = Color(0xFF8A72C4),
                                enabled = volumeLevelingConfigurable,
                                onClick = { viewModel.setVolumeLevelingStrength(strength) },
                            )
                        }
                    }

                    if (!volumeLevelingConfigurable) {
                        UnsupportedEffectText("Volume leveling is not supported by this device or audio session.")
                    }
                }
            }

            Spacer(Modifier.height(DS.Spacing.XL.scaled(metrics)))

            EffectsSectionLabel(
                icon = Icons.AutoMirrored.Filled.VolumeUp,
                tint = Color(0xFFF5921A),
                title = "Volume Boost",
                subtitle = "Loudness enhancement for quiet recordings",
            )

            Spacer(Modifier.height(DS.Spacing.SM.scaled(metrics)))

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics))) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("Volume Boost", color = colors.primaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                        Switch(
                            checked = eqState.volumeBoostEnabled && volumeBoostConfigurable,
                            onCheckedChange = { viewModel.setVolumeBoostEnabled(it) },
                            enabled = volumeBoostConfigurable,
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = Color.White,
                                checkedTrackColor = colors.accent,
                            ),
                        )
                    }

                    if (!volumeBoostConfigurable) {
                        UnsupportedEffectText("Loudness enhancement is not supported by this device or audio session.")
                    } else if (eqState.volumeBoostEnabled) {
                        Spacer(Modifier.height(DS.Spacing.MD.scaled(metrics)))

                        val gainDb = eqState.volumeBoostGainMb / 100f
                        Text(
                            text = "+${String.format(Locale.US, "%.1f", gainDb)} dB",
                            color = colors.accent,
                            fontSize = 24.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.fillMaxWidth(),
                            textAlign = TextAlign.Center,
                        )

                        Spacer(Modifier.height(DS.Spacing.SM))

                        Slider(
                            value = eqState.volumeBoostGainMb.toFloat(),
                            onValueChange = { viewModel.setVolumeBoostGain(it.toInt()) },
                            valueRange = 0f..AudioEffectsManager.MAX_VOLUME_BOOST_MB.toFloat(),
                            colors = SliderDefaults.colors(
                                thumbColor = colors.accent,
                                activeTrackColor = colors.accent,
                                inactiveTrackColor = colors.secondaryBackground,
                            ),
                        )

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Text("0 dB", color = colors.tertiaryText, fontSize = 11.sp)
                            Text("+${AudioEffectsManager.MAX_VOLUME_BOOST_MB / 100} dB", color = colors.tertiaryText, fontSize = 11.sp)
                        }

                        Spacer(Modifier.height(DS.Spacing.SM))
                        Text(
                            text = "Increases perceived loudness. High values may cause distortion.",
                            color = colors.tertiaryText,
                            fontSize = 12.sp,
                        )
                    }
                }
            }

            Spacer(Modifier.height(DS.Spacing.XL.scaled(metrics)))

            EffectsSectionLabel(
                icon = Icons.Default.Equalizer,
                tint = Color(0xFFA05252),
                title = "Bass Boost",
                subtitle = "Enhance low-frequency response",
            )

            Spacer(Modifier.height(DS.Spacing.SM.scaled(metrics)))

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics))) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("Bass Boost", color = colors.primaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                        Switch(
                            checked = eqState.bassBoostEnabled && bassBoostConfigurable,
                            onCheckedChange = { viewModel.setBassBoostEnabled(it) },
                            enabled = bassBoostConfigurable,
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = Color.White,
                                checkedTrackColor = colors.accent,
                            ),
                        )
                    }

                    if (!bassBoostConfigurable) {
                        UnsupportedEffectText("Bass boost is not supported by this device or audio session.")
                    } else if (eqState.bassBoostEnabled) {
                        Spacer(Modifier.height(DS.Spacing.MD.scaled(metrics)))

                        val strengthPct = (eqState.bassBoostStrength / 10f).toInt()
                        Text(
                            text = "$strengthPct%",
                            color = Color(0xFFA05252),
                            fontSize = 24.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.fillMaxWidth(),
                            textAlign = TextAlign.Center,
                        )

                        Spacer(Modifier.height(DS.Spacing.SM))

                        Slider(
                            value = eqState.bassBoostStrength.toFloat(),
                            onValueChange = { viewModel.setBassBoostStrength(it.toInt()) },
                            valueRange = 0f..AudioEffectsManager.MAX_BASS_BOOST.toFloat(),
                            colors = SliderDefaults.colors(
                                thumbColor = Color(0xFFA05252),
                                activeTrackColor = Color(0xFFA05252),
                                inactiveTrackColor = colors.secondaryBackground,
                            ),
                        )

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Text("Off", color = colors.tertiaryText, fontSize = 11.sp)
                            Text("Max", color = colors.tertiaryText, fontSize = 11.sp)
                        }
                    }
                }
            }

            Spacer(Modifier.height(DS.Spacing.XXXL.scaled(metrics)))
        }
    }
}

@Composable
private fun EffectsSectionLabel(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Row(
        modifier = Modifier.padding(horizontal = DS.Spacing.XL.scaled(metrics)),
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
        Spacer(Modifier.width(12.dp))
        Column {
            Text(title, color = colors.primaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text(subtitle, color = colors.secondaryText, fontSize = 12.sp)
        }
    }
}

@Composable
private fun UnsupportedEffectText(text: String) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Spacer(Modifier.height(DS.Spacing.MD.scaled(metrics)))
    Text(
        text = text,
        color = colors.tertiaryText,
        fontSize = 13.sp,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().padding(vertical = DS.Spacing.MD.scaled(metrics)),
    )
}

@Composable
private fun PresetChip(
    label: String,
    selected: Boolean,
    accentColor: Color,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val bgColor by animateColorAsState(
        targetValue = if (selected) accentColor else EnveTheme.colors.secondaryBackground,
        animationSpec = tween(200),
        label = "chipBg",
    )
    val textColor = if (selected) Color.White else EnveTheme.colors.secondaryText

    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(bgColor)
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.45f)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Text(label, color = textColor, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun EqualizerBands(
    state: EqualizerState,
    accentColor: Color,
    onBandChange: (Int, Int) -> Unit,
) {
    val colors = EnveTheme.colors
    val range = state.maxBandLevel - state.minBandLevel
    val midLevel = (state.maxBandLevel + state.minBandLevel) / 2

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text("+${state.maxBandLevel / 100} dB", color = colors.tertiaryText, fontSize = 10.sp)
        Text("0 dB", color = colors.tertiaryText, fontSize = 10.sp)
        Text("${state.minBandLevel / 100} dB", color = colors.tertiaryText, fontSize = 10.sp)
    }

    Spacer(Modifier.height(4.dp))

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(180.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
    ) {
        state.bandFrequencies.forEachIndexed { band, freq ->
            val level = state.bandLevels.getOrElse(band) { 0 }
            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                val db = level / 100f
                val dbLabel = String.format(Locale.US, "%.0f", db)
                Text(
                    text = if (db >= 0) "+$dbLabel" else dbLabel,
                    color = if (level != 0) accentColor else colors.tertiaryText,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                )

                Box(
                    modifier = Modifier
                        .weight(1f)
                        .width(40.dp)
                        .rotate(270f),
                    contentAlignment = Alignment.Center,
                ) {
                    Slider(
                        value = level.toFloat(),
                        onValueChange = { onBandChange(band, it.toInt()) },
                        valueRange = state.minBandLevel.toFloat()..state.maxBandLevel.toFloat(),
                        modifier = Modifier.width(140.dp),
                        colors = SliderDefaults.colors(
                            thumbColor = accentColor,
                            activeTrackColor = accentColor,
                            inactiveTrackColor = colors.secondaryBackground,
                        ),
                    )
                }

                Text(
                    text = formatFreq(freq),
                    color = colors.tertiaryText,
                    fontSize = 10.sp,
                )
            }
        }
    }
}

private fun formatFreq(hz: Int): String = when {
    hz >= 1000 -> "${hz / 1000}k"
    else -> "${hz}"
}

private val VolumeLevelingStrength.displayName: String
    get() = when (this) {
        VolumeLevelingStrength.OFF -> "Off"
        VolumeLevelingStrength.LOW -> "Low"
        VolumeLevelingStrength.MEDIUM -> "Medium"
        VolumeLevelingStrength.HIGH -> "High"
    }
