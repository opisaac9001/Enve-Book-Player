package com.enve.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.app.ui.components.ChromeActionButton
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.hearth.design.hearthDisplay
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.VocabViewModel
import java.text.DateFormat
import java.util.Date

@Composable
fun VocabularyHubScreen(
    onBack: () -> Unit,
    onStudy: () -> Unit,
    onSettings: () -> Unit,
    viewModel: VocabViewModel = hiltViewModel(),
) {
    val hub by viewModel.hub.collectAsStateWithLifecycle()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    var query by remember { mutableStateOf("") }

    val filtered = remember(hub.entries, query) {
        if (query.isBlank()) hub.entries
        else hub.entries.filter {
            it.word.contains(query, true) ||
                it.sentence.contains(query, true) ||
                (it.userNote?.contains(query, true) == true)
        }
    }

    SettingsScreenLayout(animatedBackground = EnveTheme.dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .statusBarsPadding()
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
                    text = "Vocabulary",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = DS.Spacing.MD.scaled(metrics)),
                )
                ChromeActionButton(
                    onClick = onSettings,
                    icon = Icons.Default.Settings,
                    contentDescription = "Vocabulary settings",
                )
            }

            SettingsCard {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(DS.Spacing.LG.scaled(metrics)),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                ) {
                    Stat("Words", hub.total, false)
                    Stat("Due", hub.due, hub.due > 0)
                    Stat("New", hub.new, false)
                }
            }

            Button(
                onClick = onStudy,
                modifier = Modifier.fillMaxWidth(),
                enabled = hub.total > 0,
                shape = RoundedCornerShape(999.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = colors.accent,
                    contentColor = colors.onAccent,
                ),
            ) {
                Icon(Icons.Default.School, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(DS.Spacing.SM))
                val studyCount = hub.due + minOf(hub.new, hub.dailyNewLimit)
                Text(if (studyCount > 0) "Study $studyCount" else "Study any word")
            }

            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                placeholder = { Text("Search words") },
                leadingIcon = { Icon(Icons.Default.Search, null) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = colors.primaryText,
                    unfocusedTextColor = colors.primaryText,
                    focusedBorderColor = colors.accent,
                ),
            )
        }

        if (filtered.isEmpty()) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (hub.total == 0)
                        "No vocabulary yet.\nTap “Define” on a selected word while reading to save it here."
                    else "No matches.",
                    color = colors.secondaryText,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.LG.scaled(metrics)),
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentPadding = PaddingValues(
                    start = DS.Spacing.LG.scaled(metrics),
                    end = DS.Spacing.LG.scaled(metrics),
                    top = DS.Spacing.MD.scaled(metrics),
                    bottom = 100.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
            ) {
                items(filtered, key = { it.id }) { entry ->
                    SettingsCard {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(DS.Spacing.MD.scaled(metrics)),
                            verticalAlignment = Alignment.Top,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        entry.word,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = DS.FontSize.Headline.scaled(metrics),
                                        color = colors.primaryText,
                                    )
                                    if (entry.isMastered) {
                                        Spacer(Modifier.width(DS.Spacing.XS))
                                        Text(
                                            "✓ mastered",
                                            fontSize = DS.FontSize.Caption2.scaled(metrics),
                                            color = colors.accent,
                                        )
                                    }
                                }
                                if (entry.sentence.isNotBlank()) {
                                    Text(
                                        "“${entry.sentence}”",
                                        fontSize = DS.FontSize.Footnote.scaled(metrics),
                                        maxLines = 3,
                                        overflow = TextOverflow.Ellipsis,
                                        color = colors.secondaryText,
                                        modifier = Modifier.padding(top = DS.Spacing.XXS),
                                    )
                                }
                                Text(
                                    DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(entry.lookedUpAt)),
                                    fontSize = DS.FontSize.Caption2.scaled(metrics),
                                    color = colors.tertiaryText,
                                    modifier = Modifier.padding(top = DS.Spacing.XXS),
                                )
                            }
                            IconButton(onClick = { viewModel.delete(entry) }) {
                                Icon(Icons.Default.Delete, "Delete", tint = colors.tertiaryText)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Stat(label: String, value: Int, emphasize: Boolean) {
    val colors = EnveTheme.colors
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            "$value",
            style = hearthDisplay(28.sp),
            color = if (emphasize) colors.accent else colors.primaryText,
        )
        Text(label, fontSize = DS.FontSize.Caption, color = colors.secondaryText)
    }
}
