package com.enve.hearth.opds

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.hearthDisplay

@Composable
internal fun SelectionMark(selected: Boolean, modifier: Modifier = Modifier) {
    val palette = Hearth.palette
    Icon(
        if (selected) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
        contentDescription = if (selected) "Selected" else "Not selected",
        tint = if (selected) palette.ember else palette.textTertiary,
        modifier = modifier.clip(CircleShape).background(palette.bg.copy(alpha = 0.7f)).size(24.dp),
    )
}

@Composable
internal fun OpdsBulkImportDialog(
    bulk: OpdsBulkImportState,
    onChoose: (bookId: String, href: String) -> Unit,
    onChooseFormat: (String) -> Unit,
    onSkip: (bookId: String) -> Unit,
    onStart: () -> Unit,
    onCancel: () -> Unit,
    onDismiss: () -> Unit,
) {
    val palette = Hearth.palette
    val isBusy = bulk.phase == OpdsBulkPhase.RESOLVING || bulk.phase == OpdsBulkPhase.IMPORTING
    Dialog(
        onDismissRequest = { if (isBusy) onCancel() else onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        LazyColumn(
            Modifier.fillMaxSize().background(palette.bg).statusBarsPadding().navigationBarsPadding(),
            contentPadding = PaddingValues(Hearth.Spacing.XXL),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        ) {
            item("header") {
                Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    Overline("Download from catalog")
                    Text(bulk.title(), style = HearthText.ScreenTitle, color = palette.text)
                    Text(bulk.summary(), style = HearthText.Body, color = palette.textSecondary)
                    when (bulk.phase) {
                        OpdsBulkPhase.RESOLVING -> LinearProgressIndicator(
                            progress = { bulk.resolved.toFloat() / bulk.items.size.coerceAtLeast(1) },
                            modifier = Modifier.fillMaxWidth(),
                            color = palette.ember,
                            trackColor = palette.bgSunken,
                        )
                        OpdsBulkPhase.IMPORTING -> LinearProgressIndicator(
                            progress = { bulk.finishedCount.toFloat() / bulk.items.size.coerceAtLeast(1) },
                            modifier = Modifier.fillMaxWidth(),
                            color = palette.ember,
                            trackColor = palette.bgSunken,
                        )
                        else -> Unit
                    }
                }
            }

            if (bulk.phase == OpdsBulkPhase.REVIEW && bulk.ambiguous.isNotEmpty() && bulk.formatChoices.size > 1) {
                item("formats") {
                    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                        Text(
                            "${bulk.ambiguous.size} books offer more than one file. Pick a type for all of them, or choose per book below.",
                            style = HearthText.Caption,
                            color = palette.textSecondary,
                        )
                        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                            bulk.formatChoices.forEach { format ->
                                HearthChip("Use $format", selected = false, onClick = { onChooseFormat(format) })
                            }
                        }
                    }
                }
            }

            items(bulk.items, key = { it.book.id }) { item ->
                BulkRow(item, isReview = bulk.phase == OpdsBulkPhase.REVIEW, onChoose = onChoose, onSkip = onSkip)
            }

            item("actions") {
                Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    when (bulk.phase) {
                        OpdsBulkPhase.RESOLVING, OpdsBulkPhase.IMPORTING -> QuietButton("Stop", onClick = onCancel)
                        OpdsBulkPhase.REVIEW -> {
                            val ready = bulk.ready.size
                            EmberButton(
                                if (ready == 1) "Download 1 book" else "Download $ready books",
                                onClick = { if (ready > 0) onStart() },
                                modifier = Modifier.weight(1f),
                            )
                            QuietButton("Cancel", onClick = onDismiss)
                        }
                        OpdsBulkPhase.FINISHED -> EmberButton("Done", onClick = onDismiss, modifier = Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

@Composable
private fun BulkRow(
    item: OpdsBulkItem,
    isReview: Boolean,
    onChoose: (bookId: String, href: String) -> Unit,
    onSkip: (bookId: String) -> Unit,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Inner)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(palette.bgElevated).border(1.dp, palette.hairline, shape).padding(Hearth.Spacing.M),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            Column(Modifier.weight(1f)) {
                Text(item.book.title, style = hearthDisplay(14.sp, FontWeight.SemiBold), color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(item.statusLabel(), style = HearthText.Caption, color = item.statusColor())
            }
            if (item.status == OpdsBulkStatus.DOWNLOADING) {
                Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = palette.ember, modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                }
            }
        }
        if (item.status == OpdsBulkStatus.DOWNLOADING && item.progress > 0f) {
            LinearProgressIndicator(progress = { item.progress }, modifier = Modifier.fillMaxWidth(), color = palette.ember, trackColor = palette.bgSunken)
        }
        if (isReview && item.status == OpdsBulkStatus.WAITING && item.options.size > 1) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                item.options.forEach { option ->
                    HearthChip(
                        listOfNotNull(option.formatLabel, option.label.takeIf { option.formatLabel == null }).joinToString(" "),
                        selected = option.href == item.chosenHref,
                        onClick = { onChoose(item.book.id, option.href) },
                    )
                }
            }
        }
        if (isReview && item.status == OpdsBulkStatus.WAITING) {
            QuietButton("Skip this book", onClick = { onSkip(item.book.id) })
        }
    }
}

private fun OpdsBulkImportState.title(): String = when (phase) {
    OpdsBulkPhase.RESOLVING -> "Checking downloads…"
    OpdsBulkPhase.REVIEW -> "Ready to download"
    OpdsBulkPhase.IMPORTING -> "Downloading…"
    OpdsBulkPhase.FINISHED -> if (wasCancelled) "Stopped" else "Finished"
}

private fun OpdsBulkImportState.summary(): String = when (phase) {
    OpdsBulkPhase.RESOLVING -> "Looked at $resolved of ${items.size} books."
    OpdsBulkPhase.REVIEW -> buildList {
        add("${ready.size} ready")
        if (ambiguous.isNotEmpty()) add("${ambiguous.size} need a file type")
        if (skippedCount > 0) add("$skippedCount can't be downloaded here")
        if (failedCount > 0) add("$failedCount couldn't be checked")
    }.joinToString(" · ")
    OpdsBulkPhase.IMPORTING -> "$finishedCount of ${items.size} done, one at a time."
    OpdsBulkPhase.FINISHED -> buildList {
        add("Downloaded $completedCount of ${items.size} books.")
        if (failedCount > 0) add("$failedCount failed.")
        if (skippedCount > 0) add("$skippedCount skipped.")
    }.joinToString(" ")
}

private fun OpdsBulkItem.statusLabel(): String = when (status) {
    OpdsBulkStatus.WAITING -> when {
        needsChoice -> "Choose a file type"
        else -> options.firstOrNull { it.href == chosenHref }?.let { option ->
            listOfNotNull(option.formatLabel, option.label).distinct().joinToString(" · ")
        } ?: "Checking…"
    }
    OpdsBulkStatus.DOWNLOADING -> if (progress > 0f) "Downloading ${(progress * 100).toInt()}%" else "Starting…"
    OpdsBulkStatus.COMPLETED -> message ?: "Downloaded"
    OpdsBulkStatus.FAILED -> message ?: "Failed"
    OpdsBulkStatus.SKIPPED -> message ?: "Skipped"
}

@Composable
private fun OpdsBulkItem.statusColor() = when (status) {
    OpdsBulkStatus.COMPLETED -> Hearth.palette.statusOK
    OpdsBulkStatus.FAILED -> Hearth.palette.statusError
    OpdsBulkStatus.SKIPPED -> Hearth.palette.statusWarn
    else -> Hearth.palette.textSecondary
}
