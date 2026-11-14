package com.enve.app.cloud

import android.text.format.Formatter
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.data.fileimport.AudioGrouping
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled

@Composable
fun CloudImportScreen(
    state: CloudImportUiState,
    onBack: () -> Unit,
    onChooseFiles: () -> Unit,
    onChooseFolder: () -> Unit,
    onOpen: (CloudEntry) -> Unit,
    onToggle: (CloudEntry) -> Unit,
    onSelectAll: () -> Unit,
    onClearSelection: () -> Unit,
    onRefresh: () -> Unit,
    onGroupingChange: (AudioGrouping) -> Unit,
    onImport: () -> Unit,
    onCancelImport: () -> Unit,
    onImportLink: (String) -> Unit,
    onDismissMessage: () -> Unit,
) {
    val colors = EnveTheme.colors
    val eink = EnveTheme.eink
    val metrics = rememberAdaptiveMetrics()
    val service = state.service
    val importing = state.progress != null
    val horizontal = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))
    var showLinkDialog by remember { mutableStateOf(false) }
    val actionColor = if (importing) colors.tertiaryText else if (eink.monochrome) colors.primaryText else colors.accent

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding()
            .navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ScreenBackButton(onClick = onBack)
            Column(Modifier.padding(start = DS.Spacing.MD.scaled(metrics))) {
                Text(
                    text = "CLOUD STORAGE",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption2.scaled(metrics),
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 4.sp,
                )
                Text(
                    text = service.displayName,
                    color = colors.primaryText,
                    fontSize = 32.sp.scaled(metrics),
                    lineHeight = 36.sp.scaled(metrics),
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Serif,
                )
            }
        }

        SettingsCard(modifier = horizontal) {
            Column(
                modifier = Modifier.padding(DS.Spacing.MD.scaled(metrics)),
                verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
            ) {
                Text(
                    text = serviceExplanation(service),
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Footnote.scaled(metrics),
                )
                OutlinedButton(onClick = onChooseFiles, enabled = !importing, modifier = Modifier.fillMaxWidth()) {
                    Text("Choose files in Android Files", color = actionColor)
                }
                OutlinedButton(onClick = onChooseFolder, enabled = !importing, modifier = Modifier.fillMaxWidth()) {
                    Text("Choose a folder in Android Files", color = actionColor)
                }
                if (service == CloudStorageService.DROPBOX) {
                    OutlinedButton(onClick = { showLinkDialog = true }, enabled = !importing, modifier = Modifier.fillMaxWidth()) {
                        Text("Paste Dropbox file link", color = actionColor)
                    }
                }
            }
        }

        if (state.browsing) {
            Row(modifier = horizontal.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = state.path.joinToString(" / ") { it.name },
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Subheadline.scaled(metrics),
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onRefresh, enabled = !state.loading) {
                    Icon(Icons.Default.Refresh, contentDescription = "Refresh", tint = colors.accent)
                }
            }
        }
        if (state.truncated) Notice("Showing the first entries only. Open a smaller folder to see everything.", horizontal)
        if (state.providerStillLoading) Notice("${service.displayName} is still fetching this folder. Refresh in a moment.", horizontal)

        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            when {
                state.loading && state.entries.isEmpty() -> CircularProgressIndicator(
                    color = colors.accent,
                    modifier = Modifier.align(Alignment.Center),
                )
                state.entries.isEmpty() -> Text(
                    text = if (state.browsing) "This folder is empty." else "Nothing chosen yet.",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Subheadline.scaled(metrics),
                    modifier = Modifier.align(Alignment.Center).padding(DS.Spacing.LG.scaled(metrics)),
                )
                else -> LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(state.entries, key = { it.uri.toString() }) { entry ->
                        EntryRow(
                            entry = entry,
                            selected = entry.key in state.selected,
                            enabled = !importing,
                            onClick = { if (entry.isDirectory) onOpen(entry) else onToggle(entry) },
                        )
                    }
                }
            }
        }

        val progress = state.progress
        if (progress != null) {
            ImportProgressCard(progress, onCancelImport, horizontal)
        } else if (state.entries.any { it.isImportable }) {
            SelectionBar(state, onSelectAll, onClearSelection, onGroupingChange, onImport, horizontal)
        }
    }

    if (showLinkDialog) {
        DropboxLinkDialog(
            onImport = { link ->
                showLinkDialog = false
                onImportLink(link)
            },
            onDismiss = { showLinkDialog = false },
        )
    }

    state.message?.let { message ->
        AlertDialog(
            onDismissRequest = onDismissMessage,
            text = { Text(message, color = colors.primaryText) },
            confirmButton = {
                TextButton(onClick = onDismissMessage) {
                    Text("OK", color = if (eink.monochrome) colors.primaryText else colors.accent)
                }
            },
            shape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(DS.Radius.Medium),
            containerColor = colors.cardBackground,
        )
    }
}

private fun serviceExplanation(service: CloudStorageService): String = buildString {
    append("Enve isn't signed in to ${service.displayName}. ")
    append("The Android Files chooser shows ${service.displayName} only when its app is installed and signed in on this device, ")
    append("and some providers don't let you choose a whole folder. ")
    append("Enve copies the books you pick into this profile for offline reading and listening, and never changes them in ${service.displayName}.")
    if (service == CloudStorageService.DROPBOX) {
        append(" Without the Dropbox app, paste a link to a single file shared with anyone who has the link.")
    }
}

@Composable
private fun DropboxLinkDialog(onImport: (String) -> Unit, onDismiss: () -> Unit) {
    val colors = EnveTheme.colors
    val eink = EnveTheme.eink
    val metrics = rememberAdaptiveMetrics()
    val tint = if (eink.monochrome) colors.primaryText else colors.accent
    val shape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(DS.Radius.Medium)
    var link by remember { mutableStateOf("") }
    val ready = link.isNotBlank()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Paste Dropbox file link", color = colors.primaryText) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
                Text(
                    "Use a link to one audiobook or ebook file, shared with anyone who has the link. Folder links aren't supported. Enve downloads the file directly from Dropbox and doesn't keep the link.",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Footnote.scaled(metrics),
                )
                OutlinedTextField(
                    value = link,
                    onValueChange = { link = it },
                    placeholder = { Text("https://www.dropbox.com/scl/fi/…") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { if (ready) onImport(link) }),
                    shape = shape,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = colors.primaryText,
                        unfocusedTextColor = colors.primaryText,
                        focusedBorderColor = tint,
                        cursorColor = tint,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onImport(link) }, enabled = ready) {
                Text("Import", color = if (ready) tint else colors.tertiaryText, fontWeight = FontWeight.SemiBold)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel", color = colors.secondaryText)
            }
        },
        shape = shape,
        containerColor = colors.cardBackground,
    )
}

@Composable
private fun Notice(text: String, modifier: Modifier) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Text(text = text, color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics), modifier = modifier)
}

@Composable
private fun EntryRow(entry: CloudEntry, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = EnveTheme.colors
    val eink = EnveTheme.eink
    val metrics = rememberAdaptiveMetrics()
    val context = LocalContext.current
    val supported = entry.isDirectory || entry.isImportable
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled && supported, onClick = onClick)
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {
        Icon(
            imageVector = if (entry.isDirectory) Icons.Default.Folder else Icons.Default.Description,
            contentDescription = null,
            tint = when {
                eink.monochrome -> colors.primaryText
                entry.isDirectory -> colors.accent
                supported -> colors.secondaryText
                else -> colors.tertiaryText
            },
            modifier = Modifier.size(22.dp.scaled(metrics)),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = entry.name,
                color = if (supported) colors.primaryText else colors.tertiaryText,
                fontSize = DS.FontSize.Body.scaled(metrics),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (!entry.isDirectory) {
                Text(
                    text = buildList {
                        if (entry.sizeBytes >= 0L) add(Formatter.formatShortFileSize(context, entry.sizeBytes))
                        if (!supported) add("Not a supported book format")
                    }.joinToString(" • "),
                    color = colors.tertiaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
        }
        if (entry.isDirectory) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = colors.tertiaryText)
        } else if (supported) {
            Checkbox(
                checked = selected,
                onCheckedChange = { onClick() },
                enabled = enabled,
                colors = CheckboxDefaults.colors(
                    checkedColor = if (eink.monochrome) colors.primaryText else colors.accent,
                    uncheckedColor = colors.secondaryText,
                ),
            )
        }
    }
}

@Composable
private fun SelectionBar(
    state: CloudImportUiState,
    onSelectAll: () -> Unit,
    onClearSelection: () -> Unit,
    onGroupingChange: (AudioGrouping) -> Unit,
    onImport: () -> Unit,
    modifier: Modifier,
) {
    val colors = EnveTheme.colors
    val eink = EnveTheme.eink
    val metrics = rememberAdaptiveMetrics()
    val count = state.selectedFiles.size
    SettingsCard(modifier = modifier.padding(bottom = DS.Spacing.MD.scaled(metrics))) {
        Column(
            modifier = Modifier.padding(DS.Spacing.MD.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
        ) {
            if (state.selectedAudioCount > 1) {
                Text("Audio files", color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
                    listOf(
                        AudioGrouping.AUTOMATIC to "Automatic",
                        AudioGrouping.SINGLE_BOOK to "One audiobook",
                        AudioGrouping.SEPARATE to "Separate",
                    ).forEach { (grouping, label) ->
                        FilterChip(
                            selected = state.grouping == grouping,
                            onClick = { onGroupingChange(grouping) },
                            label = { Text(label, fontSize = DS.FontSize.Caption.scaled(metrics)) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = if (eink.suppressGradients) colors.secondaryBackground else colors.accent.copy(alpha = 0.18f),
                                selectedLabelColor = colors.primaryText,
                                labelColor = colors.secondaryText,
                            ),
                        )
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = if (count == 0) onSelectAll else onClearSelection) {
                    Text(if (count == 0) "Select all" else "Clear", color = colors.secondaryText)
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onImport, enabled = count > 0) {
                    Text(
                        text = if (count == 1) "Import 1 file" else "Import $count files",
                        color = if (count > 0) (if (eink.monochrome) colors.primaryText else colors.accent) else colors.tertiaryText,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }
    }
}

@Composable
private fun ImportProgressCard(progress: CloudImportProgress, onCancel: () -> Unit, modifier: Modifier) {
    val colors = EnveTheme.colors
    val eink = EnveTheme.eink
    val metrics = rememberAdaptiveMetrics()
    val context = LocalContext.current
    val tint = if (eink.monochrome) colors.primaryText else colors.accent
    SettingsCard(modifier = modifier.padding(bottom = DS.Spacing.MD.scaled(metrics))) {
        Column(
            modifier = Modifier.padding(DS.Spacing.MD.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
        ) {
            Text(
                text = progress.title,
                color = colors.primaryText,
                fontSize = DS.FontSize.Subheadline.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val copied = Formatter.formatShortFileSize(context, progress.copiedBytes)
            Text(
                text = buildString {
                    append("Book ${progress.itemNumber} of ${progress.itemCount} • $copied")
                    if (progress.totalBytes > 0L) append(" of ${Formatter.formatShortFileSize(context, progress.totalBytes)}")
                },
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
            if (progress.totalBytes > 0L) {
                LinearProgressIndicator(
                    progress = { (progress.copiedBytes.toFloat() / progress.totalBytes).coerceIn(0f, 1f) },
                    color = tint,
                    trackColor = colors.separator,
                    modifier = Modifier.fillMaxWidth(),
                )
            } else {
                LinearProgressIndicator(color = tint, trackColor = colors.separator, modifier = Modifier.fillMaxWidth())
            }
            Row {
                Spacer(Modifier.weight(1f))
                OutlinedButton(onClick = onCancel) {
                    Text("Cancel", color = colors.secondaryText)
                }
            }
        }
    }
}
