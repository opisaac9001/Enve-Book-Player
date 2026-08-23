package com.enve.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.VocabViewModel
import com.enve.hearth.design.hearthDisplay
import kotlinx.coroutines.launch

@Composable
fun VocabSettingsScreen(
    onBack: () -> Unit,
    viewModel: VocabViewModel = hiltViewModel(),
) {
    val s by viewModel.settings.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    SettingsScreenLayout(animatedBackground = EnveTheme.dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .statusBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = onBack)
                Text(
                    text = "Vocabulary Settings",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = DS.Spacing.MD.scaled(metrics)),
                )
            }

            SettingsCard {
                Column(
                    modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
                ) {
                    ToggleRow(
                        "Auto-save lookups",
                        "When on, every word you tap Define on is saved to Vocabulary automatically.",
                        s.autoLog,
                    ) { scope.launch { viewModel.setAutoLog(it) } }

                    StepperRow(
                        "New cards per session",
                        "How many never-seen words to introduce per study session.",
                        s.dailyNewLimit,
                    ) { scope.launch { viewModel.setDailyNewLimit(it) } }

                    ToggleRow(
                        "Show sentence first",
                        "Card front shows the sentence with a blank instead of the word (cloze style).",
                        s.showSentenceFirst,
                    ) { scope.launch { viewModel.setShowSentenceFirst(it) } }

                    ToggleRow(
                        "Shuffle queue",
                        "Randomise the order of due and new cards within each study session.",
                        s.shuffleQueue,
                    ) { scope.launch { viewModel.setShuffleQueue(it) } }
                }
            }
        }
    }
}

@Composable
private fun ToggleRow(title: String, subtitle: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    val colors = EnveTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = colors.primaryText)
            Text(subtitle, fontSize = 12.sp, color = colors.tertiaryText)
        }
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = colors.onAccent,
                checkedTrackColor = colors.accent,
            ),
        )
    }
}

@Composable
private fun StepperRow(title: String, subtitle: String, value: Int, onChange: (Int) -> Unit) {
    val colors = EnveTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = colors.primaryText)
            Text(subtitle, fontSize = 12.sp, color = colors.tertiaryText)
        }
        IconButton(onClick = { onChange((value - 5).coerceAtLeast(0)) }) {
            Text("−", fontSize = 20.sp, color = colors.secondaryText)
        }
        Text("$value", fontWeight = FontWeight.Bold, color = colors.primaryText)
        IconButton(onClick = { onChange((value + 5).coerceAtMost(100)) }) {
            Text("+", fontSize = 20.sp, color = colors.secondaryText)
        }
    }
}
