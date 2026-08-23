package com.enve.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.ReaderAnnotation
import com.enve.app.viewmodel.TocEntry

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TocSheet(
    tocEntries: List<TocEntry>,
    bookmarks: List<ReaderAnnotation>,
    annotations: List<ReaderAnnotation>,
    colors: ChromeColors,
    onTocSelect: (TocEntry) -> Unit,
    onSeek: (String?) -> Unit,
    onDeleteAnnotation: (ReaderAnnotation) -> Unit,
    onClose: () -> Unit,
) {
    var tab by remember { mutableIntStateOf(0) }
    val tabs = listOf("Contents", "Bookmarks", "Highlights", "Notes")

    val highlights = remember(annotations) { annotations.filter { AnnotationKind.parse(it.kind) == AnnotationKind.HIGHLIGHT } }
    val noteRows   = remember(annotations) { annotations.filter { AnnotationKind.parse(it.kind) == AnnotationKind.NOTE } }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding(),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Reader", color = colors.primaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                 modifier = Modifier.weight(1f))
            IconButton(onClick = onClose) { Icon(Icons.Default.Close, "Close", tint = colors.secondaryText) }
        }
        TabRow(
            selectedTabIndex = tab,
            containerColor   = colors.surface,
            contentColor     = colors.accentText,
        ) {
            tabs.forEachIndexed { i, t ->
                Tab(selected = tab == i, onClick = { tab = i },
                    text = { Text(t, fontSize = 13.sp) })
            }
        }
        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 500.dp)
                .padding(top = 4.dp),
        ) {
            when (tab) {
                0 -> {
                    if (tocEntries.isEmpty()) {
                        item { EmptySheetPlaceholder("No table of contents available", colors) }
                    } else {
                        items(tocEntries) { entry ->
                            TocRow(entry, colors) { onTocSelect(entry) }
                        }
                    }
                }
                1 -> {
                    if (bookmarks.isEmpty()) {
                        item { EmptySheetPlaceholder("No bookmarks yet.\nTap the bookmark icon in the top bar to add one.", colors) }
                    } else {
                        items(bookmarks, key = { it.id }) { bm ->
                            BookmarkRow(bm, colors, onSeek = { onSeek(bm.locatorJson) }, onDelete = { onDeleteAnnotation(bm) })
                        }
                    }
                }
                2 -> {
                    if (highlights.isEmpty()) {
                        item { EmptySheetPlaceholder("No highlights yet.\nSelect text and tap a colour to add one.", colors) }
                    } else {
                        items(highlights, key = { it.id }) { ann ->
                            AnnotationRow(ann, colors, onSeek = { onSeek(ann.locatorJson) }, onDelete = { onDeleteAnnotation(ann) })
                        }
                    }
                }
                3 -> {
                    if (noteRows.isEmpty()) {
                        item { EmptySheetPlaceholder("No notes yet.\nTap “New Note” in the top bar or add one from a selection.", colors) }
                    } else {
                        items(noteRows, key = { it.id }) { ann ->
                            NoteRow(ann, colors, onSeek = { onSeek(ann.locatorJson) }, onDelete = { onDeleteAnnotation(ann) })
                        }
                    }
                }
            }
        }
    }
}

@Composable private fun EmptySheetPlaceholder(text: String, colors: ChromeColors) {
    Box(modifier = Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
        Text(text, color = colors.secondaryText, fontSize = 14.sp, textAlign = TextAlign.Center)
    }
}

@Composable private fun TocRow(entry: TocEntry, colors: ChromeColors, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(start = (16 + entry.depth * 12).dp, end = 16.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.AutoMirrored.Filled.MenuBook, null, tint = colors.accentText.copy(alpha = 0.7f), modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(10.dp))
        Text(entry.title.ifBlank { "(untitled)" }, color = colors.primaryText, fontSize = 14.sp,
             maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
    HorizontalDivider(color = colors.divider)
}

@Composable private fun BookmarkRow(bm: ReaderAnnotation, colors: ChromeColors, onSeek: () -> Unit, onDelete: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onSeek)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Bookmark, null, tint = colors.accentText, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(bm.selectedText.ifBlank { "Bookmark" }, color = colors.primaryText, fontSize = 14.sp,
                 maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (bm.note.isNotBlank())
                Text(bm.note, color = colors.secondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        IconButton(onClick = onDelete, modifier = Modifier.size(32.dp)) {
            Icon(Icons.Default.DeleteOutline, "Delete", tint = colors.secondaryText, modifier = Modifier.size(16.dp))
        }
    }
    HorizontalDivider(color = colors.divider)
}

@Composable private fun AnnotationRow(ann: ReaderAnnotation, colors: ChromeColors, onSeek: () -> Unit, onDelete: () -> Unit) {
    val styleColor = Color(parseHexColor(ann.colorHex))
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onSeek)
            .padding(16.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(modifier = Modifier
            .size(width = 4.dp, height = 36.dp)
            .clip(RoundedCornerShape(2.dp))
            .background(styleColor))
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            if (ann.selectedText.isNotBlank())
                Text(ann.selectedText, color = colors.primaryText, fontSize = 13.sp,
                     maxLines = 3, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium)
            if (ann.note.isNotBlank())
                Text(ann.note, color = colors.secondaryText, fontSize = 12.sp,
                     maxLines = 2, overflow = TextOverflow.Ellipsis,
                     modifier = Modifier.padding(top = 2.dp))
            Text(
                AnnotationStyle.valueOf(ann.style).label,
                color    = styleColor.copy(alpha = 0.8f),
                fontSize = 10.sp,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
        IconButton(onClick = onDelete, modifier = Modifier.size(32.dp)) {
            Icon(Icons.Default.DeleteOutline, "Delete", tint = colors.secondaryText, modifier = Modifier.size(16.dp))
        }
    }
    HorizontalDivider(color = colors.divider)
}

@Composable private fun NoteRow(ann: ReaderAnnotation, colors: ChromeColors, onSeek: () -> Unit, onDelete: () -> Unit) {
    val accent = Color(parseHexColor(ann.colorHex))
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onSeek)
            .padding(16.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(modifier = Modifier
            .size(width = 4.dp, height = 36.dp)
            .clip(RoundedCornerShape(2.dp))
            .background(accent))
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            val body = ann.note.ifBlank { "(empty note)" }
            Text(body, color = colors.primaryText, fontSize = 13.sp,
                 maxLines = 4, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium)
            if (ann.selectedText.isNotBlank())
                Text("“${ann.selectedText}”", color = colors.secondaryText, fontSize = 12.sp,
                     maxLines = 2, overflow = TextOverflow.Ellipsis,
                     modifier = Modifier.padding(top = 2.dp))
        }
        IconButton(onClick = onDelete, modifier = Modifier.size(32.dp)) {
            Icon(Icons.Default.DeleteOutline, "Delete", tint = colors.secondaryText, modifier = Modifier.size(16.dp))
        }
    }
    HorizontalDivider(color = colors.divider)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AddAnnotationDialog(
    initialText: String,
    chromeColors: ChromeColors,
    onSave: (AnnotationStyle, String, String) -> Unit,
    onDismiss: () -> Unit,
) {
    var style by remember { mutableStateOf(AnnotationStyle.HIGHLIGHT) }
    var note  by remember { mutableStateOf("") }
    val colors = listOf("#FFF59D", "#A5D6A7", "#90CAF9", "#F8BBD0", "#FFCC80", "#CE93D8")
    var selectedColor by remember { mutableStateOf(colors[0]) }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor   = chromeColors.background,
        title = { Text("Add Annotation", color = chromeColors.primaryText, fontWeight = FontWeight.Bold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (initialText.isNotBlank()) {
                    Text(
                        "“${initialText.take(120)}${if (initialText.length > 120) "…" else "”"}",
                        color    = chromeColors.secondaryText,
                        fontSize = 13.sp,
                    )
                }
                Text("Style", color = chromeColors.secondaryText, fontSize = 12.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    AnnotationStyle.entries.forEach { s ->
                        SheetChip(s.label, style == s, chromeColors) { style = s }
                    }
                }
                Text("Color", color = chromeColors.secondaryText, fontSize = 12.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    colors.forEach { hex ->
                        Box(
                            modifier = Modifier
                                .size(28.dp)
                                .clip(CircleShape)
                                .background(Color(parseHexColor(hex)))
                                .then(if (hex == selectedColor) Modifier.border(2.dp, Color.White, CircleShape) else Modifier)
                                .clickable { selectedColor = hex },
                        )
                    }
                }
                OutlinedTextField(
                    value = note, onValueChange = { note = it },
                    label = { Text("Add a private note (optional)") },
                    minLines = 2,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor   = chromeColors.accentText,
                        unfocusedBorderColor = chromeColors.divider,
                        focusedTextColor     = chromeColors.primaryText,
                        unfocusedTextColor   = chromeColors.primaryText,
                        cursorColor          = chromeColors.accentText,
                    ),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(style, selectedColor, note) }) {
                Text("Save", color = chromeColors.accentText, fontWeight = FontWeight.Bold)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel", color = chromeColors.secondaryText) }
        },
    )
}
