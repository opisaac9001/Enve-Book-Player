package com.enve.hearth.player

import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.ContentCut
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FormatQuote
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.AudiobookBookmark
import com.enve.engine.playback.AudiobookClip
import com.enve.engine.playback.ClipTranscriptionModel
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.HearthToggleRow
import com.enve.hearth.design.Overline
import com.enve.hearth.design.hearthDisplay
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayerSheets(sheet: PlayerSheet?, vm: HearthPlayerViewModel, onDismiss: () -> Unit) {
    ClipDialogs(vm)
    if (sheet == null) return
    val palette = Hearth.palette
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = palette.bgElevated,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(bottom = Hearth.Spacing.XXL)) {
            when (sheet) {
                PlayerSheet.SPEED -> SpeedSheet(vm)
                PlayerSheet.SLEEP -> SleepSheet(vm, onDismiss)
                PlayerSheet.CHAPTERS -> ChaptersSheet(vm, onDismiss)
                PlayerSheet.BOOKMARKS -> BookmarksSheet(vm)
                PlayerSheet.QUEUE -> QueueSheet(vm, onDismiss)
                PlayerSheet.AMBIENT -> AmbientSheet(vm)
            }
        }
    }
}

@Composable
private fun QueueSheet(vm: HearthPlayerViewModel, onDismiss: () -> Unit) {
    val queue by vm.queue.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Overline("Up Next")
        if (queue.isNotEmpty()) {
            Box(
                Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(50))
                    .clickable(role = Role.Button, onClickLabel = "Clear Up Next") { vm.clearQueue() }
                    .padding(horizontal = Hearth.Spacing.M),
                contentAlignment = Alignment.Center,
            ) {
                Text("Clear", style = HearthText.Caption, color = palette.ember)
            }
        }
    }
    Spacer(Modifier.size(Hearth.Spacing.S))
    if (queue.isEmpty()) {
        Text("Add books from the library to keep listening.", style = HearthText.Body, color = palette.textSecondary)
        return
    }
    LazyColumn(Modifier.heightIn(max = 460.dp)) {
        items(queue, key = { it.book.uniqueKey }) { item ->
            val index = queue.indexOfFirst { it.book.uniqueKey == item.book.uniqueKey }
            Row(
                Modifier.fillMaxWidth().clickable {
                    vm.playQueued(item.book.uniqueKey)
                    onDismiss()
                }.padding(vertical = Hearth.Spacing.S),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                CoverTile(
                    model = item.book.coverUrl,
                    mediaType = item.book.mediaType,
                    modifier = Modifier.width(42.dp),
                )
                Column(Modifier.weight(1f)) {
                    Text(item.book.title, style = HearthText.Label, color = palette.text, maxLines = 2)
                    item.book.author?.takeIf { it.isNotBlank() }?.let {
                        Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 1)
                    }
                }
                SheetIconButton(
                    Icons.Outlined.ArrowUpward,
                    contentDescription = "Move ${item.book.title} earlier",
                    enabled = index > 0,
                    onClick = { vm.moveQueuedUp(item.book.uniqueKey) },
                )
                SheetIconButton(
                    Icons.Outlined.ArrowDownward,
                    contentDescription = "Move ${item.book.title} later",
                    enabled = index in 0 until queue.lastIndex,
                    onClick = { vm.moveQueuedDown(item.book.uniqueKey) },
                )
                SheetIconButton(
                    Icons.Outlined.Delete,
                    contentDescription = "Remove ${item.book.title} from Up Next",
                    onClick = { vm.removeQueued(item.book.uniqueKey) },
                    tint = palette.textTertiary,
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SpeedSheet(vm: HearthPlayerViewModel) {
    val transport by vm.transport.collectAsStateWithLifecycle()
    Overline("Speed")
    Spacer(Modifier.size(Hearth.Spacing.M))
    FlowRow(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        listOf(0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f, 2.5f, 3.0f).forEach { s ->
            HearthChip(speedLabel(s), selected = kotlin.math.abs(transport.speed - s) < 0.01f, onClick = { vm.setSpeed(s) })
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SleepSheet(vm: HearthPlayerViewModel, onDismiss: () -> Unit) {
    var tab by remember { mutableStateOf(SleepSheetTab.TIMER) }
    SleepSheetTabs(tab = tab, onSelect = { tab = it })
    Spacer(Modifier.size(Hearth.Spacing.L))
    if (tab == SleepSheetTab.INSIGHTS) {
        SleepInsightsSheet(vm)
        return
    }
    val remaining by vm.sleepRemainingSec.collectAsStateWithLifecycle()
    val chapters by vm.chapters.collectAsStateWithLifecycle()
    val idx by vm.currentChapterIndex.collectAsStateWithLifecycle()
    val remainingNow = remaining
    Overline(if (remainingNow != null) "Sleep in ${remainingNow / 60}m" else "Sleep timer")
    Spacer(Modifier.size(Hearth.Spacing.M))
    FlowRow(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        listOf(5, 10, 15, 30, 45, 60, 90).forEach { min ->
            HearthChip("${min}m", selected = false, onClick = { vm.startSleep(min); onDismiss() })
        }
        val chapterEndSec = chapters.getOrNull(idx)?.endTime
        if (chapterEndSec != null) {
            HearthChip("End of chapter", selected = false, onClick = { vm.startChapterSleep(chapterEndSec); onDismiss() })
            val nextEndSec = chapters.getOrNull(idx + 1)?.endTime
            if (nextEndSec != null) {
                HearthChip("End of next chapter", selected = false, onClick = { vm.startChapterSleep(nextEndSec); onDismiss() })
            }
        }
        if (remaining != null) {
            HearthChip("Off", selected = false, onClick = { vm.cancelSleep(); onDismiss() })
        }
    }
    Spacer(Modifier.size(Hearth.Spacing.XL))
    SleepAutomationSection(vm)
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SleepAutomationSection(vm: HearthPlayerViewModel) {
    val settings by vm.sleepAutomation.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    var editingTime by remember { mutableStateOf<BedtimeBoundary?>(null) }
    Column(Modifier.fillMaxWidth().heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
        if (vm.shakeAvailable) {
            HearthToggleRow("Shake to snooze", settings.shakeToSnoozeEnabled) { enabled ->
                vm.updateSleepAutomation { it.copy(shakeToSnoozeEnabled = enabled) }
            }
            Text("Shake the phone while the timer runs to keep listening.", style = HearthText.Caption, color = palette.textTertiary)
            if (settings.shakeToSnoozeEnabled) {
                Spacer(Modifier.size(Hearth.Spacing.S))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    listOf(5, 10, 15, 20, 30).forEach { minutes ->
                        HearthChip("Snooze ${minutes}m", selected = settings.snoozeMinutes == minutes, onClick = {
                            vm.updateSleepAutomation { it.copy(snoozeMinutes = minutes) }
                        })
                    }
                }
            }
            Spacer(Modifier.size(Hearth.Spacing.L))
        }
        HearthToggleRow("Bedtime auto-sleep", settings.autoSleepEnabled) { enabled ->
            vm.updateSleepAutomation { it.copy(autoSleepEnabled = enabled) }
        }
        Text(
            "Arm the sleep timer automatically when you listen during these hours.",
            style = HearthText.Caption,
            color = palette.textTertiary,
        )
        if (settings.autoSleepEnabled) {
            Spacer(Modifier.size(Hearth.Spacing.S))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                Text("From", style = HearthText.Caption, color = palette.textSecondary)
                HearthChip(minutesOfDayLabel(settings.autoSleepStartMinutes), selected = false, onClick = { editingTime = BedtimeBoundary.START })
                Text("to", style = HearthText.Caption, color = palette.textSecondary)
                HearthChip(minutesOfDayLabel(settings.autoSleepEndMinutes), selected = false, onClick = { editingTime = BedtimeBoundary.END })
            }
            Spacer(Modifier.size(Hearth.Spacing.S))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                listOf(15, 20, 30, 45, 60, 90).forEach { minutes ->
                    HearthChip("${minutes}m timer", selected = settings.autoSleepTimerMinutes == minutes, onClick = {
                        vm.updateSleepAutomation { it.copy(autoSleepTimerMinutes = minutes) }
                    })
                }
            }
        }
    }
    editingTime?.let { boundary ->
        val initial = if (boundary == BedtimeBoundary.START) settings.autoSleepStartMinutes else settings.autoSleepEndMinutes
        BedtimeTimeDialog(
            title = if (boundary == BedtimeBoundary.START) "Bedtime starts" else "Bedtime ends",
            initialMinutes = initial,
            onDismiss = { editingTime = null },
            onConfirm = { minutes ->
                editingTime = null
                vm.updateSleepAutomation {
                    if (boundary == BedtimeBoundary.START) it.copy(autoSleepStartMinutes = minutes) else it.copy(autoSleepEndMinutes = minutes)
                }
            },
        )
    }
}

private enum class BedtimeBoundary { START, END }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BedtimeTimeDialog(title: String, initialMinutes: Int, onDismiss: () -> Unit, onConfirm: (Int) -> Unit) {
    val context = LocalContext.current
    val state = rememberTimePickerState(
        initialHour = initialMinutes / 60,
        initialMinute = initialMinutes % 60,
        is24Hour = DateFormat.is24HourFormat(context),
    )
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { TimePicker(state = state) },
        confirmButton = { TextButton(onClick = { onConfirm(state.hour * 60 + state.minute) }) { Text("Set") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

private fun minutesOfDayLabel(minutes: Int): String =
    LocalTime.of(minutes / 60, minutes % 60).format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT))

@Composable
private fun ChaptersSheet(vm: HearthPlayerViewModel, onDismiss: () -> Unit) {
    val chapters by vm.chapters.collectAsStateWithLifecycle()
    val idx by vm.currentChapterIndex.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    Overline("Chapters")
    Spacer(Modifier.size(Hearth.Spacing.S))
    if (chapters.isEmpty()) {
        Text("No chapters", style = HearthText.Body, color = palette.textSecondary)
        return
    }
    LazyColumn(Modifier.heightIn(max = 420.dp)) {
        items(chapters, key = { it.index }) { c ->
            val isCurrent = c.index == idx
            Row(
                Modifier.fillMaxWidth().clickable { vm.seekToChapter(c); onDismiss() }.padding(vertical = Hearth.Spacing.M),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    c.title,
                    style = hearthDisplay(16.sp, if (isCurrent) FontWeight.SemiBold else FontWeight.Normal),
                    color = if (isCurrent) palette.ember else palette.text,
                    modifier = Modifier.weight(1f),
                )
                Text(fmtSec(c.startTime), style = HearthText.Caption, color = palette.textTertiary)
            }
        }
    }
}

@Composable
private fun BookmarksSheet(vm: HearthPlayerViewModel) {
    val bookmarks by vm.bookmarks.collectAsStateWithLifecycle()
    val clips by vm.clips.collectAsStateWithLifecycle()
    val clipBookKey by vm.clipBookKey.collectAsStateWithLifecycle()
    val clipBusyId by vm.clipBusyId.collectAsStateWithLifecycle()
    val transcriptionModel by vm.transcriptionModel.collectAsStateWithLifecycle()
    val transport by vm.transport.collectAsStateWithLifecycle()
    val clipsByBookmark = remember(clips) { clips.associateBy { it.bookmarkId } }
    val palette = Hearth.palette
    var adding by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }
    var draft by remember { mutableStateOf<ClipDraft?>(null) }
    var modelPrompt by remember { mutableStateOf<Pair<AudiobookClip, String>?>(null) }
    val clipKey = clipBookKey?.takeIf { transport.durationMs > 0L }
    draft?.let { active ->
        ClipEditor(
            draft = active,
            onCancel = { draft = null },
            onSave = { startMs, endMs, clipNote ->
                vm.saveClip(active.bookKey, active.bookmarkId, active.anchorMs, startMs, endMs, clipNote)
                draft = null
            },
        )
        return
    }

    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Overline("Bookmarks")
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (clipKey != null) {
                SheetIconButton(Icons.Outlined.ContentCut, "Clip this moment", tint = palette.ember, onClick = {
                    draft = ClipDraft(clipKey, null, transport.positionMs, transport.durationMs, null, null, null)
                })
            }
            Row(
                Modifier.clip(RoundedCornerShape(50)).clickable { adding = true }.padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.XS),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Add, contentDescription = "Add bookmark", tint = palette.ember, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(Hearth.Spacing.XS))
                Text("Add", style = HearthText.Caption, color = palette.ember)
            }
        }
    }
    (transcriptionModel as? ClipTranscriptionModel.Installing)?.let {
        Text("Downloading speech model ${(it.progress * 100).toInt()}%", style = HearthText.Caption, color = palette.textTertiary)
    }
    if (clipBookKey == null) {
        Text("Download this book to cut clips from it.", style = HearthText.Caption, color = palette.textTertiary)
    }
    Spacer(Modifier.size(Hearth.Spacing.S))
    if (bookmarks.isEmpty()) {
        Text("Nothing marked yet.", style = HearthText.Body, color = palette.textSecondary)
    } else {
        LazyColumn(Modifier.heightIn(max = 420.dp)) {
            items(bookmarks, key = { it.id }) { b ->
                val clip = clipsByBookmark[b.id]
                BookmarkRow(
                    b = b,
                    clip = clip,
                    busy = clipBusyId == b.id,
                    clipActions = BookmarkClipActions(
                        canClip = clipKey != null,
                        onEdit = {
                            clipKey?.let { key ->
                                draft = ClipDraft(key, b.id, b.position * 1000, transport.durationMs, clip?.startMs, clip?.endMs, b.note)
                            }
                        },
                        onShare = { clip?.let(vm::shareClip) },
                        onTranscript = {
                            if (clip != null) {
                                if (clip.transcript != null || transcriptionModel is ClipTranscriptionModel.Ready) {
                                    vm.showTranscript(clip, b.title)
                                } else if (transcriptionModel is ClipTranscriptionModel.Missing) {
                                    modelPrompt = clip to b.title
                                }
                            }
                        },
                        onRemove = { clip?.let(vm::deleteClip) },
                    ),
                    onSeek = { vm.seekToBookmark(b) },
                    onDelete = { vm.deleteBookmark(b) },
                )
            }
        }
    }
    val prompted = modelPrompt
    val missingModel = transcriptionModel as? ClipTranscriptionModel.Missing
    if (prompted != null && missingModel != null) {
        TranscriptionModelDialog(
            sizeBytes = missingModel.sizeBytes,
            onDownload = {
                modelPrompt = null
                vm.installModelAndTranscribe(prompted.first, prompted.second)
            },
            onDismiss = { modelPrompt = null },
        )
    }
    if (adding) {
        AlertDialog(
            onDismissRequest = { adding = false },
            title = { Text("Add bookmark") },
            text = {
                OutlinedTextField(
                    value = note,
                    onValueChange = { note = it.take(1500) },
                    label = { Text("Note") },
                    minLines = 3,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    vm.addBookmark(note.trim().takeIf { it.isNotBlank() })
                    note = ""
                    adding = false
                }) { Text("Save") }
            },
            dismissButton = {
                TextButton(onClick = { adding = false }) { Text("Cancel") }
            },
        )
    }
}

private class BookmarkClipActions(
    val canClip: Boolean,
    val onEdit: () -> Unit,
    val onShare: () -> Unit,
    val onTranscript: () -> Unit,
    val onRemove: () -> Unit,
)

@Composable
private fun BookmarkRow(
    b: AudiobookBookmark,
    clip: AudiobookClip?,
    busy: Boolean,
    clipActions: BookmarkClipActions,
    onSeek: () -> Unit,
    onDelete: () -> Unit,
) {
    val palette = Hearth.palette
    var menuOpen by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onSeek).padding(vertical = Hearth.Spacing.M),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(b.title, style = HearthText.Label, color = palette.text, maxLines = 1)
            b.note?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 2)
            }
            val where = listOfNotNull(b.chapterTitle?.takeIf { it.isNotBlank() }, fmtSec(b.position)).joinToString(" · ")
            Text(where, style = HearthText.Caption, color = palette.textTertiary)
            clip?.let {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.ContentCut, contentDescription = null, tint = palette.ember, modifier = Modifier.size(12.dp))
                    Spacer(Modifier.size(Hearth.Spacing.XS))
                    Text("Clip ${fmtSec(it.startMs / 1000)} – ${fmtSec(it.endMs / 1000)}", style = HearthText.Caption, color = palette.ember)
                }
            }
        }
        if (busy) {
            Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = palette.ember, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
            }
        } else if (clip != null || clipActions.canClip) {
            Box {
                SheetIconButton(Icons.Outlined.ContentCut, "Clip options for ${b.title}", { menuOpen = true })
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }, containerColor = palette.bgElevated) {
                    if (clip != null) {
                        ClipMenuItem("Share clip", Icons.Outlined.Share) { menuOpen = false; clipActions.onShare() }
                        ClipMenuItem("Transcript", Icons.Outlined.FormatQuote) { menuOpen = false; clipActions.onTranscript() }
                        if (clipActions.canClip) ClipMenuItem("Edit clip", Icons.Outlined.Edit) { menuOpen = false; clipActions.onEdit() }
                        ClipMenuItem("Remove clip", Icons.Outlined.Delete) { menuOpen = false; clipActions.onRemove() }
                    } else {
                        ClipMenuItem("Clip", Icons.Outlined.ContentCut) { menuOpen = false; clipActions.onEdit() }
                    }
                }
            }
        }
        SheetIconButton(Icons.Outlined.Delete, "Delete bookmark ${b.title}", onDelete, tint = palette.textTertiary)
    }
}

@Composable
private fun ClipMenuItem(label: String, icon: ImageVector, onClick: () -> Unit) {
    val palette = Hearth.palette
    DropdownMenuItem(
        text = { Text(label, color = palette.text) },
        leadingIcon = { Icon(icon, contentDescription = null, tint = palette.textSecondary) },
        onClick = onClick,
    )
}

@Composable
private fun SheetIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    tint: Color = Hearth.palette.textSecondary,
) {
    val palette = Hearth.palette
    Box(
        Modifier.size(48.dp).clip(CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (enabled) tint else palette.textTertiary.copy(alpha = 0.35f),
            modifier = Modifier.size(20.dp),
        )
    }
}

internal fun speedLabel(s: Float): String {
    val str = if (s % 1f == 0f) s.toInt().toString() else s.toString().trimEnd('0').trimEnd('.')
    return "${str}×"
}

internal fun fmtSec(seconds: Long): String {
    val s = seconds.coerceAtLeast(0)
    val h = s / 3600; val m = (s % 3600) / 60; val sec = s % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, sec) else "%d:%02d".format(m, sec)
}
