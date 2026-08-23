package com.enve.app.ui.screens

import android.content.Intent
import android.net.Uri
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
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Article
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsHeroHeader
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.SettingsSectionHeader
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.ObsidianSyncViewModel
import com.enve.hearth.design.hearthDisplay

@Composable
fun ObsidianSyncScreen(
    onBack: () -> Unit,
    viewModel: ObsidianSyncViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsState()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val context = LocalContext.current
    val folderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        runCatching {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }
        viewModel.setVaultUri(uri.toString())
    }

    SettingsScreenLayout(animatedBackground = EnveTheme.dynamicBackgroundEnabled) {
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
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = onBack)
                Text(
                    text = "Obsidian Sync",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
            }

            SettingsHeroHeader(
                title = "Obsidian Sync",
                subtitle = "Markdown notes for highlights, bookmarks, and reading notes.",
                icon = Icons.AutoMirrored.Filled.Article,
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(title = "Vault")
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                ) {
                    Icon(
                        imageVector = if (state.treeUri == null) Icons.Default.Folder else Icons.Default.CheckCircle,
                        contentDescription = null,
                        tint = if (state.treeUri == null) colors.tertiaryText else colors.accent,
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = state.treeUri?.let(::folderLabel) ?: "No vault selected",
                            color = colors.primaryText,
                            fontSize = DS.FontSize.Body.scaled(metrics),
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            text = "${state.annotationCount} annotations ready",
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                        )
                    }
                }
                HorizontalDivider(
                    color = colors.separator.copy(alpha = 0.3f),
                    modifier = Modifier.padding(vertical = DS.Spacing.MD.scaled(metrics)),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
                    Button(
                        onClick = { folderPicker.launch(null) },
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(999.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = colors.accent,
                            contentColor = Color.White,
                        ),
                    ) {
                        Icon(Icons.Default.Folder, contentDescription = null)
                        Text("Choose Folder", modifier = Modifier.padding(start = 6.dp))
                    }
                    if (state.treeUri != null) {
                        OutlinedButton(
                            onClick = viewModel::clearVault,
                            modifier = Modifier.weight(1f),
                            shape = RoundedCornerShape(999.dp),
                            border = BorderStroke(1.dp, ErrorRed),
                        ) {
                            Text("Disconnect", color = ErrorRed)
                        }
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(title = "Export")
                Button(
                    onClick = viewModel::exportNow,
                    enabled = state.treeUri != null && state.annotationCount > 0 && !state.isExporting,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(999.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = colors.accent,
                        contentColor = Color.White,
                    ),
                ) {
                    if (state.isExporting) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = colors.onAccent,
                        )
                    } else {
                        Icon(Icons.Default.IosShare, contentDescription = null)
                    }
                    Text("Export Markdown", modifier = Modifier.padding(start = 8.dp))
                }
            }

            val transient = state.error ?: state.message
            transient?.let { text ->
                val mono = EnveTheme.eink.monochrome
                val errorTint = if (mono) colors.primaryText else ErrorRed
                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.Article,
                            contentDescription = null,
                            tint = if (state.error == null) colors.accent else errorTint,
                        )
                        Text(
                            text = if (mono && state.error != null) "⚠ $text" else text,
                            color = if (state.error == null) colors.secondaryText else errorTint,
                            fontSize = DS.FontSize.Body.scaled(metrics),
                            modifier = Modifier
                                .weight(1f)
                                .padding(horizontal = DS.Spacing.MD.scaled(metrics)),
                        )
                        TextButton(onClick = viewModel::clearTransientMessage) {
                            Text("Dismiss")
                        }
                    }
                }
            }

            Spacer(Modifier.height(80.dp.scaled(metrics)))
        }
    }
}

private fun folderLabel(uriString: String): String {
    val tail = Uri.parse(uriString).lastPathSegment.orEmpty()
    return Uri.decode(tail.substringAfterLast(':')).ifBlank { "Selected vault" }
}

private val ErrorRed = Color(0xFFB3453E)
