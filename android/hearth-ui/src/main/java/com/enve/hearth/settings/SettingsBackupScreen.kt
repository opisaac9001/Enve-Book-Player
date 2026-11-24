package com.enve.hearth.settings

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.engine.backup.SettingsExportResult
import com.enve.engine.backup.SettingsImportInspection
import com.enve.engine.backup.SettingsImportPreview
import com.enve.engine.backup.SettingsImportRejection
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.shell.profileViewModel
import java.text.DateFormat
import java.util.Date

@Composable
fun SettingsBackupScreen(
    onBack: () -> Unit,
    vm: SettingsBackupViewModel = profileViewModel(),
) {
    val palette = Hearth.palette
    val state by vm.state.collectAsStateWithLifecycle()

    val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        uri?.let { vm.export(it.toString()) }
    }
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { vm.inspect(it.toString()) }
    }

    state.preview?.let { preview ->
        ImportPreviewDialog(preview, applying = state.applying, onConfirm = vm::confirmImport, onDismiss = vm::dismissPreview)
    }

    Column(Modifier.fillMaxSize().background(palette.bg)) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.AutoMirrored.Outlined.ArrowBack, "Back", tint = palette.text,
                modifier = Modifier.clip(CircleShape).clickable(onClick = onBack)
                    .padding(Hearth.Spacing.S).size(26.dp),
            )
            Spacer(Modifier.size(Hearth.Spacing.S))
            Column {
                Overline("This profile")
                Text("Settings backup", style = HearthText.ScreenTitle, color = palette.text, modifier = Modifier.semantics { heading() })
            }
        }

        LazyColumn(
            contentPadding = PaddingValues(
                start = Hearth.Spacing.XL, end = Hearth.Spacing.XL,
                top = Hearth.Spacing.S, bottom = LocalMantelInset.current + Hearth.Spacing.XL,
            ),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXL),
        ) {
            item {
                Card {
                    Overline("Export")
                    Spacer(Modifier.size(Hearth.Spacing.M))
                    Text(
                        "Save this profile's appearance, playback, reading, and home screen settings to a JSON file.",
                        style = HearthText.Body,
                        color = palette.textSecondary,
                    )
                    Spacer(Modifier.size(Hearth.Spacing.L))
                    ActionButton(
                        if (state.exporting) "Saving…" else "Export settings",
                        enabled = !state.busy,
                        onClick = { exportLauncher.launch("Enve Settings.json") },
                    )
                    state.exportResult?.let { result ->
                        StatusText(
                            when (result) {
                                is SettingsExportResult.Exported -> "Saved ${result.settingCount} settings."
                                SettingsExportResult.Failed -> "Couldn't save the file. Choose another location and try again."
                            },
                            error = result == SettingsExportResult.Failed,
                        )
                    }
                }
            }
            item {
                Card {
                    Overline("Import")
                    Spacer(Modifier.size(Hearth.Spacing.M))
                    Text(
                        "Restore settings from an Enve for Android settings backup. You'll see every change before anything is applied. Settings the file doesn't include stay as they are.",
                        style = HearthText.Body,
                        color = palette.textSecondary,
                    )
                    Spacer(Modifier.size(Hearth.Spacing.L))
                    ActionButton(
                        if (state.inspecting) "Checking file…" else "Choose backup file",
                        enabled = !state.busy,
                        onClick = { importLauncher.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) },
                    )
                    if (state.inspecting) {
                        Spacer(Modifier.size(Hearth.Spacing.M))
                        QuietButton("Cancel", onClick = vm::cancelInspection)
                    }
                    state.rejection?.let { StatusText(it.message(), error = true) }
                    state.importedCount?.let { StatusText("Imported $it ${if (it == 1) "setting" else "settings"}.", error = false) }
                    if (state.importFailed) {
                        StatusText("Couldn't save every setting. Some may not have changed. Try importing again.", error = true)
                    }
                }
            }
            item {
                Text(
                    "Backups never include server addresses, accounts, passwords, tokens, PINs, library selections, books, progress, highlights, or downloads. Backups from Enve on iPhone or iPad use a different format and can't be imported here.",
                    style = HearthText.Caption,
                    color = palette.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun ActionButton(text: String, enabled: Boolean, onClick: () -> Unit) {
    EmberButton(
        text,
        onClick = { if (enabled) onClick() },
        modifier = Modifier
            .fillMaxWidth()
            .alpha(if (enabled) 1f else 0.45f)
            .semantics { if (!enabled) disabled() },
    )
}

@Composable
private fun StatusText(text: String, error: Boolean) {
    val palette = Hearth.palette
    Text(
        text,
        style = HearthText.Caption,
        color = if (error) palette.statusError else palette.statusOK,
        modifier = Modifier.padding(top = Hearth.Spacing.M).semantics { liveRegion = LiveRegionMode.Polite },
    )
}

@Composable
private fun ImportPreviewDialog(
    preview: SettingsImportPreview,
    applying: Boolean,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    val palette = Hearth.palette
    val canImport = preview.changes.isNotEmpty() && !applying
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = onConfirm, enabled = canImport) {
                Text(if (applying) "Importing…" else "Import", color = if (canImport) palette.ember else palette.textTertiary)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !applying) { Text("Cancel", color = palette.textSecondary) }
        },
        title = {
            Text(
                if (preview.changes.isEmpty()) "Nothing to change" else "Import ${preview.changes.size} ${if (preview.changes.size == 1) "change" else "changes"}?",
                color = palette.text,
            )
        },
        text = {
            Column(
                Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                preview.exportedAtMillis?.let {
                    Text(
                        "Backup from ${DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it))}",
                        style = HearthText.Caption,
                        color = palette.textSecondary,
                    )
                }
                preview.changes.forEach { change ->
                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Inner)).background(palette.bgSunken)
                            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
                    ) {
                        Text(change.label, style = HearthText.Label, color = palette.text)
                        Text("${change.current} → ${change.incoming}", style = HearthText.Caption, color = palette.textSecondary)
                    }
                }
                val notes = buildList {
                    if (preview.unchangedCount > 0) add("${preview.unchangedCount} already match")
                    if (preview.ignoredKeys.isNotEmpty()) add("${preview.ignoredKeys.size} unrecognised skipped")
                }
                if (notes.isNotEmpty()) {
                    Text(notes.joinToString(" · "), style = HearthText.Caption, color = palette.textTertiary)
                }
            }
        },
        containerColor = palette.bgElevated,
    )
}

@Composable
private fun Card(content: @Composable ColumnScope.() -> Unit) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Card)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape).padding(Hearth.Spacing.L),
        content = content,
    )
}

private fun SettingsImportInspection.Rejected.message(): String = when (reason) {
    SettingsImportRejection.UNREADABLE -> "Couldn't open that file. Choose it again."
    SettingsImportRejection.TOO_LARGE -> "That file is too large to be a settings backup."
    SettingsImportRejection.NOT_JSON -> "That file isn't an Enve settings backup."
    SettingsImportRejection.NOT_ANDROID_SETTINGS ->
        "This isn't an Enve for Android settings backup. Backups from Enve on iPhone or iPad can't be imported here."
    SettingsImportRejection.NEWER_VERSION -> "This backup was made by a newer version of Enve. Update the app and try again."
    SettingsImportRejection.INVALID_VALUES ->
        "This backup has invalid values (${invalidFields.joinToString(", ")}). Nothing was changed."
}
