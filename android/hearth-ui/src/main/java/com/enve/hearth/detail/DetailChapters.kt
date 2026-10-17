package com.enve.hearth.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.core.data.model.Book
import com.enve.core.data.model.Chapter
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.ShelfHeader

@Composable
internal fun ChaptersSection(
    b: Book,
    chapters: List<Chapter>,
    loading: Boolean,
    failed: Boolean,
    onRetry: () -> Unit,
    onListenAt: (Book, Long) -> Unit,
    canSeparate: (Chapter) -> Boolean,
    onSeparate: (Chapter) -> Unit,
) {
    val palette = Hearth.palette
    var expanded by remember { mutableStateOf(false) }
    var menuChapter by remember { mutableStateOf<Chapter?>(null) }
    var pendingSeparation by remember { mutableStateOf<Chapter?>(null) }
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.XL)) {
        ShelfHeader("Chapters", modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(Hearth.Spacing.S))
        when {
            loading -> Text("Looking for chapter marks…", style = HearthText.Caption, color = palette.textTertiary)
            failed -> Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Couldn't load chapters.",
                    style = HearthText.Body, color = palette.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                QuietButton(text = "Retry", onClick = onRetry)
            }
            chapters.isEmpty() -> Text(
                "This book arrived without chapter marks.",
                style = HearthText.Body, color = palette.textSecondary,
            )
            else -> {
                val currentSec = b.currentTime
                val shown = if (expanded) chapters else chapters.take(8)
                shown.forEachIndexed { i, ch ->
                    val current = currentSec in ch.startTime until ch.endTime && currentSec > 0
                    Box {
                        Row(
                            Modifier.fillMaxWidth()
                                .combinedClickable(
                                    onClick = { onListenAt(b, ch.startTime * 1000L) },
                                    onLongClick = { if (canSeparate(ch)) menuChapter = ch },
                                )
                                .padding(vertical = Hearth.Spacing.S),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                ch.title.ifBlank { "Chapter ${ch.index + 1}" },
                                style = HearthText.Body,
                                color = if (current) palette.ember else palette.text,
                                maxLines = 1, overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            Text(fmtChapter(ch.duration), style = HearthText.Caption, color = palette.textTertiary)
                        }
                        DropdownMenu(
                            expanded = menuChapter == ch,
                            onDismissRequest = { menuChapter = null },
                        ) {
                            DropdownMenuItem(
                                text = { Text("Separate into book") },
                                onClick = {
                                    menuChapter = null
                                    pendingSeparation = ch
                                },
                            )
                        }
                    }
                    if (i != shown.lastIndex) Box(Modifier.fillMaxWidth().height(1.dp).background(palette.hairline))
                }
                if (chapters.size > 8) {
                    Text(
                        if (expanded) "Fewer chapters" else "All ${chapters.size} chapters",
                        style = HearthText.Label, color = palette.ember,
                        modifier = Modifier.clip(RoundedCornerShape(50)).clickable { expanded = !expanded }
                            .padding(vertical = Hearth.Spacing.S),
                    )
                }
            }
        }
    }
    pendingSeparation?.let { chapter ->
        AlertDialog(
            onDismissRequest = { pendingSeparation = null },
            title = { Text("Separate into book?") },
            text = {
                Text("Makes \"${chapter.title.ifBlank { "Chapter ${chapter.index + 1}" }}\" its own book in your library. The audio file stays where it is.")
            },
            confirmButton = {
                TextButton(onClick = {
                    pendingSeparation = null
                    onSeparate(chapter)
                }) { Text("Separate") }
            },
            dismissButton = {
                TextButton(onClick = { pendingSeparation = null }) { Text("Cancel") }
            },
        )
    }
}

internal fun fmtChapter(sec: Long): String {
    val h = sec / 3600
    val m = (sec % 3600) / 60
    return when {
        h > 0 -> "${h}h ${m}m"
        m > 0 -> "${m}m"
        else -> "${sec}s"
    }
}
