package com.enve.app.ui.screens

import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.DictionariesSettingsViewModel
import com.enve.hearth.design.hearthDisplay

@Composable
fun DictionariesSettingsScreen(
    onBack: () -> Unit,
    viewModel: DictionariesSettingsViewModel = hiltViewModel(),
) {
    val dictionaries by viewModel.dictionaries.collectAsStateWithLifecycle()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val context = LocalContext.current
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var lastInstalled by remember { mutableStateOf<String?>(null) }

    val folderPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        context.contentResolver.takePersistableUriPermission(
            uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION,
        )
        try {
            val installed = viewModel.installFromFolder(uri)
            lastInstalled = installed.displayName
        } catch (e: Exception) {
            errorMessage = e.message ?: "Couldn't add dictionary"
        }
    }

    SettingsScreenLayout(animatedBackground = EnveTheme.dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
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
                    text = "Dictionaries",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
            }

            Text(
                "Add a folder containing StarDict files (.ifo, .idx, .dict[.dz], and optional .syn). Free dictionaries are at stardict.sourceforge.net and freedict.org.",
                fontSize = DS.FontSize.Footnote.scaled(metrics),
                color = colors.secondaryText,
            )

            Button(
                onClick = { folderPicker.launch(null) },
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(
                    containerColor = colors.accent,
                    contentColor = colors.onAccent,
                ),
            ) {
                Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(DS.Spacing.SM))
                Text("Add Dictionary")
            }

            lastInstalled?.let {
                Text(
                    "Installed \"$it\".",
                    color = colors.accent,
                    fontSize = DS.FontSize.Footnote.scaled(metrics),
                )
            }

            if (dictionaries.isEmpty()) {
                SettingsCard {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics)),
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                    ) {
                        Text(
                            "No Dictionaries Installed",
                            color = colors.primaryText,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            "Definitions fall back to the online service (dictionaryapi.dev) until you add one.",
                            fontSize = DS.FontSize.Footnote.scaled(metrics),
                            color = colors.secondaryText,
                        )
                    }
                }
            } else {
                Text(
                    "INSTALLED",
                    color = colors.tertiaryText,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 11.sp,
                    letterSpacing = 1.6.sp,
                )
                SettingsCard {
                    dictionaries.forEachIndexed { index, dict ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(dict.displayName, fontWeight = FontWeight.Medium, color = colors.primaryText)
                                Text(
                                    "${dict.wordCount} entries",
                                    fontSize = DS.FontSize.Caption.scaled(metrics),
                                    color = colors.secondaryText,
                                )
                            }
                            IconButton(onClick = { viewModel.delete(dict.slug) }) {
                                Icon(
                                    Icons.Default.Delete,
                                    contentDescription = "Delete",
                                    tint = if (EnveTheme.eink.monochrome) colors.primaryText else ErrorRed,
                                )
                            }
                        }
                        if (index < dictionaries.lastIndex) {
                            HorizontalDivider(color = colors.separator.copy(alpha = 0.3f))
                        }
                    }
                }
            }

            Spacer(Modifier.height(80.dp.scaled(metrics)))
        }
    }

    if (errorMessage != null) {
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            title = { Text("Couldn't add dictionary") },
            text = { Text(errorMessage!!) },
            confirmButton = {
                TextButton(onClick = { errorMessage = null }) { Text("OK") }
            },
        )
    }
}

private val ErrorRed = Color(0xFFB3453E)
