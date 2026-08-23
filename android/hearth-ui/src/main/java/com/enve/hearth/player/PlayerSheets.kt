package com.enve.hearth.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.AudiobookBookmark
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.hearthDisplay

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayerSheets(sheet: PlayerSheet?, vm: HearthPlayerViewModel, onDismiss: () -> Unit) {
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
            Text(
                "Clear",
                style = HearthText.Caption,
                color = palette.ember,
                modifier = Modifier.clip(RoundedCornerShape(50)).clickable { vm.clearQueue() }
                    .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.XS),
            )
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
                CoverTile(model = item.book.coverUrl, modifier = Modifier.width(42.dp))
                Column(Modifier.weight(1f)) {
                    Text(item.book.title, style = HearthText.Label, color = palette.text, maxLines = 2)
                    item.book.author?.takeIf { it.isNotBlank() }?.let {
                        Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 1)
                    }
                }
                Icon(
                    Icons.Outlined.ArrowUpward,
                    contentDescription = "Move ${item.book.title} earlier",
                    tint = if (index > 0) palette.textSecondary else palette.textTertiary.copy(alpha = 0.35f),
                    modifier = Modifier.clip(RoundedCornerShape(50))
                        .then(if (index > 0) Modifier.clickable { vm.moveQueuedUp(item.book.uniqueKey) } else Modifier)
                        .padding(Hearth.Spacing.XS).size(19.dp),
                )
                Icon(
                    Icons.Outlined.ArrowDownward,
                    contentDescription = "Move ${item.book.title} later",
                    tint = if (index in 0 until queue.lastIndex) palette.textSecondary else palette.textTertiary.copy(alpha = 0.35f),
                    modifier = Modifier.clip(RoundedCornerShape(50))
                        .then(if (index in 0 until queue.lastIndex) Modifier.clickable { vm.moveQueuedDown(item.book.uniqueKey) } else Modifier)
                        .padding(Hearth.Spacing.XS).size(19.dp),
                )
                Icon(
                    Icons.Outlined.Delete,
                    contentDescription = "Remove ${item.book.title} from Up Next",
                    tint = palette.textTertiary,
                    modifier = Modifier.clip(RoundedCornerShape(50)).clickable { vm.removeQueued(item.book.uniqueKey) }
                        .padding(Hearth.Spacing.XS).size(19.dp),
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
}

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
    val palette = Hearth.palette
    var adding by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Overline("Bookmarks")
        Row(
            Modifier.clip(RoundedCornerShape(50)).clickable { adding = true }.padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.XS),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.Add, contentDescription = "Add bookmark", tint = palette.ember, modifier = Modifier.size(18.dp))
            Spacer(Modifier.size(Hearth.Spacing.XS))
            Text("Add", style = HearthText.Caption, color = palette.ember)
        }
    }
    Spacer(Modifier.size(Hearth.Spacing.S))
    if (bookmarks.isEmpty()) {
        Text("Nothing marked yet.", style = HearthText.Body, color = palette.textSecondary)
    } else {
        LazyColumn(Modifier.heightIn(max = 420.dp)) {
            items(bookmarks, key = { it.id }) { b ->
                BookmarkRow(b, onSeek = { vm.seekToBookmark(b) }, onDelete = { vm.deleteBookmark(b) })
            }
        }
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

@Composable
private fun BookmarkRow(b: AudiobookBookmark, onSeek: () -> Unit, onDelete: () -> Unit) {
    val palette = Hearth.palette
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
        }
        Icon(
            Icons.Outlined.Delete, contentDescription = "Delete",
            tint = palette.textTertiary,
            modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onDelete).padding(Hearth.Spacing.XS).size(20.dp),
        )
    }
}

internal fun speedLabel(s: Float): String {
    val str = if (s % 1f == 0f) s.toInt().toString() else s.toString().trimEnd('0').trimEnd('.')
    return "${str}×"
}

private fun fmtSec(seconds: Long): String {
    val s = seconds.coerceAtLeast(0)
    val h = s / 3600; val m = (s % 3600) / 60; val sec = s % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, sec) else "%d:%02d".format(m, sec)
}
