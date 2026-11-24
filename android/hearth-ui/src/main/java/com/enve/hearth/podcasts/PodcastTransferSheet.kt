package com.enve.hearth.podcasts

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.engine.podcasts.PodcastImportCandidate
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.HearthToggleRow
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.hearthUI

private val opmlMimeTypes = arrayOf("text/x-opml", "text/xml", "application/xml", "application/octet-stream", "text/plain")

@Composable
internal fun PodcastTransferSheet(vm: PodcastTransferViewModel, onClose: () -> Unit) {
    val state by vm.state.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    val resolver = LocalContext.current.contentResolver
    val openFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) vm.preview { resolver.openInputStream(uri) }
    }
    val saveFile = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/x-opml")) { uri ->
        if (uri != null) vm.saveExport { resolver.openOutputStream(uri, "wt") }
    }
    val close = {
        vm.cancelExport()
        vm.dismissImport()
        onClose()
    }

    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        LazyColumn(
            Modifier.fillMaxSize().background(palette.bg).statusBarsPadding().navigationBarsPadding(),
            contentPadding = PaddingValues(Hearth.Spacing.XXL),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
        ) {
            item {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Overline("Move podcasts", Modifier.weight(1f))
                    TextButton(onClick = close) { Text("Close", color = palette.textSecondary) }
                }
                Text("Import & export", style = HearthText.ScreenTitle, color = palette.text)
            }

            item {
                PodcastCard {
                    Text("Import", style = hearthUI(15.sp, FontWeight.SemiBold), color = palette.text)
                    Text(
                        "Bring your shows over with an OPML file. Overcast exports with listening history also restore what you've played; newer progress in Enve is never replaced.",
                        style = HearthText.Caption,
                        color = palette.textSecondary,
                    )
                    when {
                        state.isReadingFile -> Busy("Reading the file…")
                        state.isImporting -> {
                            val progress = state.importProgress
                            Busy(
                                if (progress == null || progress.total == 0) "Adding shows…"
                                else "Restoring history: ${progress.completed} of ${progress.total} shows",
                            )
                            QuietButton("Stop import", onClick = vm::cancelImport)
                        }
                        state.preview == null -> EmberButton("Choose OPML file", onClick = { openFile.launch(opmlMimeTypes) })
                    }
                    state.importError?.let { Text(it, style = HearthText.Body, color = palette.statusError) }
                    if (state.importInterrupted) {
                        Text(
                            "The import stopped early. Shows already added stay; import the same file again to finish without duplicates.",
                            style = HearthText.Body,
                            color = palette.statusWarn,
                        )
                    }
                    state.report?.let { report ->
                        report.summaryLines.forEach { Text(it, style = HearthText.Body, color = palette.text) }
                        QuietButton("Done", onClick = vm::dismissImport)
                    }
                }
            }

            state.preview?.takeIf { !state.isImporting }?.let { preview ->
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                        Text(
                            buildList {
                                add(if (preview.candidates.size == 1) "1 show" else "${preview.candidates.size} shows")
                                if (preview.alreadySubscribedCount > 0) add("${preview.alreadySubscribedCount} already followed")
                                if (preview.listeningStateCount > 0) add(if (preview.listeningStateCount == 1) "1 episode with history" else "${preview.listeningStateCount} episodes with history")
                                if (preview.duplicateCount > 0) add(if (preview.duplicateCount == 1) "1 duplicate merged" else "${preview.duplicateCount} duplicates merged")
                                if (preview.invalidCount > 0) add("${preview.invalidCount} unreadable feeds skipped")
                            }.joinToString(" · "),
                            style = HearthText.Caption,
                            color = palette.textSecondary,
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                            QuietButton("Select all", onClick = vm::selectAll)
                            QuietButton("Select none", onClick = vm::selectNone)
                        }
                    }
                }
                items(preview.candidates, key = PodcastImportCandidate::key) { candidate ->
                    CandidateRow(candidate, selected = candidate.key in state.selection, onToggle = { vm.toggle(candidate.key) })
                }
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                        EmberButton(
                            if (state.selection.size == 1) "Import 1 show" else "Import ${state.selection.size} shows",
                            onClick = vm::startImport,
                            modifier = Modifier.dimmedUnless(state.selection.isNotEmpty()),
                        )
                        QuietButton("Cancel", onClick = vm::dismissImport)
                    }
                }
            }

            item {
                PodcastCard {
                    Text("Export", style = hearthUI(15.sp, FontWeight.SemiBold), color = palette.text)
                    Text(
                        "Save your followed shows as OPML for another podcast app. Feeds that look private are left out unless you include them.",
                        style = HearthText.Caption,
                        color = palette.textSecondary,
                    )
                    HearthToggleRow("Include listening history", state.includeProgress, vm::setIncludeProgress)
                    HearthToggleRow("Include private feeds", state.includePrivateFeeds, vm::setIncludePrivateFeeds)
                    val export = state.export
                    when {
                        state.isExporting -> {
                            val progress = state.exportProgress
                            Busy(
                                if (progress == null || progress.total == 0) "Preparing…"
                                else "Reading episodes: ${progress.completed} of ${progress.total} shows",
                            )
                            QuietButton("Cancel", onClick = vm::cancelExport)
                        }
                        export == null -> EmberButton("Prepare export", onClick = vm::prepareExport)
                        else -> {
                            Text(
                                (if (export.feedCount == 1) "1 show" else "${export.feedCount} shows") +
                                    " · " + (if (export.episodeStateCount == 1) "1 episode with history" else "${export.episodeStateCount} episodes with history"),
                                style = HearthText.Body,
                                color = palette.text,
                            )
                            if (export.exclusions.isNotEmpty()) {
                                Text("Left out:", style = HearthText.Caption.copy(fontWeight = FontWeight.SemiBold), color = palette.text)
                                export.exclusions.forEach {
                                    Text("${it.title} — ${it.concern.explanation}", style = HearthText.Caption, color = palette.textSecondary)
                                }
                            }
                            if (export.feedsWithoutProgress.isNotEmpty()) {
                                Text(
                                    "History wasn't included for shows that couldn't be loaded: ${export.feedsWithoutProgress.joinToString(", ")}.",
                                    style = HearthText.Caption,
                                    color = palette.statusWarn,
                                )
                            }
                            EmberButton("Save file", onClick = { saveFile.launch("Enve Podcasts.opml") })
                            if (state.exportSaved) Text("Saved.", style = HearthText.Body, color = palette.statusOK)
                        }
                    }
                    state.exportError?.let { Text(it, style = HearthText.Body, color = palette.statusError) }
                }
            }
        }
    }
}

@Composable
private fun CandidateRow(candidate: PodcastImportCandidate, selected: Boolean, onToggle: () -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(value = selected, role = Role.Checkbox, onValueChange = { onToggle() }),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Checkbox(
            checked = selected,
            onCheckedChange = null,
            colors = CheckboxDefaults.colors(checkedColor = palette.ember, uncheckedColor = palette.textTertiary, checkmarkColor = palette.readableOnEmber),
        )
        Column(Modifier.weight(1f)) {
            Text(candidate.title, style = hearthUI(14.sp, FontWeight.SemiBold), color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val details = buildList {
                if (candidate.isAlreadySubscribed) add("Already followed")
                if (!candidate.isSubscribedInSource) add("Unsubscribed in the other app")
                if (candidate.playedCount > 0) add("${candidate.playedCount} played")
                if (candidate.inProgressCount > 0) add("${candidate.inProgressCount} in progress")
            }
            if (details.isNotEmpty()) Text(details.joinToString(" · "), style = HearthText.Caption, color = palette.textSecondary)
        }
    }
}

@Composable
private fun Busy(label: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        CircularProgressIndicator(color = Hearth.palette.ember, modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
        Text(label, style = HearthText.Body, color = Hearth.palette.text)
    }
}
