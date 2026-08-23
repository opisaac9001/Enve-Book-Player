package com.enve.app.ui.screens.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.app.data.reader.CustomFont
import com.enve.app.data.reader.MAX_READER_FONT_SCALE
import com.enve.app.data.reader.MIN_READER_FONT_SCALE
import com.enve.app.data.reader.READER_FONT_SCALE_STEP
import com.enve.app.data.reader.ReaderFont
import com.enve.app.data.reader.ReaderProgressDisplay
import com.enve.app.data.reader.ReaderTheme
import com.enve.app.viewmodel.ReaderUiState
import com.enve.app.viewmodel.ReaderViewModel
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.ReaderAnnotation
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.hearthDisplay
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HearthReaderSheets(vm: ReaderViewModel, state: ReaderUiState) {
    val palette = Hearth.palette
    val customFonts by vm.customFonts.collectAsStateWithLifecycle()

    val sheetShape = if (Hearth.eink.sharpCorners) {
        androidx.compose.ui.graphics.RectangleShape
    } else {
        androidx.compose.material3.BottomSheetDefaults.ExpandedShape
    }
    if (state.showAppearanceSheet) {
        ModalBottomSheet(onDismissRequest = { vm.showAppearance(false) }, shape = sheetShape, containerColor = palette.bgElevated) {
            AppearanceSheet(vm, state, customFonts)
        }
    }
    if (state.showTocSheet) {
        ModalBottomSheet(onDismissRequest = { vm.showToc(false) }, shape = sheetShape, containerColor = palette.bgElevated) {
            ContentsSheet(vm, state)
        }
    }
    if (state.showSearchSheet) {
        ModalBottomSheet(
            onDismissRequest = { vm.showSearch(false) },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            shape = sheetShape,
            containerColor = palette.bgElevated,
        ) {
            SearchSheet(vm, state)
        }
    }
    if (state.showReadAloudSheet) {
        ModalBottomSheet(onDismissRequest = { vm.showReadAloudSheet(false) }, shape = sheetShape, containerColor = palette.bgElevated) {
            ReadAloudSheet(vm, state)
        }
    }
    if (state.showAnnotationDialog) {
        ModalBottomSheet(
            onDismissRequest = { vm.showAnnotationDialog(false); vm.hideSelectionPopup() },
            shape = sheetShape,
            containerColor = palette.bgElevated,
        ) {
            NoteSheet(vm, state)
        }
    }
}

@Composable
private fun NoteSheet(vm: ReaderViewModel, state: ReaderUiState) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    var note by remember { mutableStateOf("") }
    var ink by remember { mutableStateOf(NARRATION_INKS[0]) }
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(bottom = Hearth.Spacing.XXL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L)) {
        Overline("Add a note")
        if (state.selectionText.isNotBlank()) {
            Text(
                "“${state.selectionText}”",
                style = HearthText.Caption,
                color = palette.textSecondary,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Box(Modifier.fillMaxWidth().clip(shape).background(palette.bg).border(1.dp, palette.hairline, shape).padding(Hearth.Spacing.M)) {
            if (note.isEmpty()) Text("Your note…", style = HearthText.Body, color = palette.textTertiary)
            BasicTextField(
                value = note,
                onValueChange = { note = it },
                textStyle = HearthText.Body.copy(color = palette.text),
                cursorBrush = SolidColor(palette.ember),
                modifier = Modifier.fillMaxWidth().heightIn(min = 72.dp),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            NARRATION_INKS.forEach { hex ->
                val selected = hex == ink
                Box(
                    Modifier.size(30.dp).clip(CircleShape).background(parseHex(hex))
                        .border(if (selected) 2.dp else 0.dp, if (selected) palette.ember else Color.Transparent, CircleShape)
                        .clickable { ink = hex },
                )
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            Text(
                "Cancel", style = HearthText.Label, color = palette.textSecondary,
                modifier = Modifier.clip(RoundedCornerShape(50)).clickable { vm.showAnnotationDialog(false); vm.hideSelectionPopup() }
                    .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M),
            )
            Spacer(Modifier.weight(1f))
            Text(
                "Save note", style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold), color = palette.readableOnEmber,
                modifier = Modifier.clip(RoundedCornerShape(50)).background(palette.ember)
                    .clickable {
                        state.pendingSelection?.let { vm.addAnnotation(it, AnnotationStyle.HIGHLIGHT, ink, note, state.selectionText) }
                        vm.showAnnotationDialog(false)
                        vm.hideSelectionPopup()
                    }
                    .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M),
            )
        }
    }
}

private val NARRATION_INKS = listOf("#FFF59D", "#A5D6A7", "#90CAF9", "#F8BBD0")

@Composable
private fun ReadAloudSheet(vm: ReaderViewModel, state: ReaderUiState) {
    val palette = Hearth.palette
    val prefs = state.prefs
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(bottom = Hearth.Spacing.XXL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L)) {
        Overline("Read Aloud")

        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            listOf(0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f, 2.5f, 3.0f).forEach { s ->
                HearthChip(
                    if (s == s.toInt().toFloat()) "${s.toInt()}×" else "$s×",
                    selected = kotlin.math.abs(prefs.readAloudSpeed - s) < 0.01f,
                    onClick = { vm.setReadAlongSpeed(s) },
                )
            }
        }

        Stepper(
            "Sync offset", "%+.1fs".format(prefs.readAloudSyncOffsetMs / 1000f),
            { vm.updatePreferences(prefs.copy(readAloudSyncOffsetMs = (prefs.readAloudSyncOffsetMs - 100).coerceIn(-1000, 1000))) },
            { vm.updatePreferences(prefs.copy(readAloudSyncOffsetMs = (prefs.readAloudSyncOffsetMs + 100).coerceIn(-1000, 1000))) },
        )

        ToggleRow("Highlight read aloud", prefs.readAloudHighlight) { vm.updatePreferences(prefs.copy(readAloudHighlight = it)) }
        if (prefs.readAloudHighlight) {
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                NARRATION_INKS.forEach { hex ->
                    val selected = hex.equals(prefs.readAloudHighlightHex, ignoreCase = true)
                    Box(
                        Modifier.size(30.dp).clip(CircleShape).background(parseHex(hex))
                            .border(if (selected) 2.dp else 0.dp, if (selected) palette.ember else Color.Transparent, CircleShape)
                            .clickable { vm.updatePreferences(prefs.copy(readAloudHighlightHex = hex)) },
                    )
                }
            }
        }
        ToggleRow("Turn pages with read aloud", prefs.readAloudAutoTurn) { vm.updatePreferences(prefs.copy(readAloudAutoTurn = it)) }
        ToggleRow("Skip footnotes & page numbers", prefs.readAloudSkipAsides) { vm.updatePreferences(prefs.copy(readAloudSkipAsides = it)) }

        Overline("Clips in this chapter")
        if (state.readAlongChapterClips.isEmpty()) {
            Empty("Start read aloud to load this chapter's clips.")
        } else {
            LazyColumn(Modifier.heightIn(max = 300.dp)) {
                items(state.readAlongChapterClips) { row ->
                    val current = row.index == state.readAlongClipIndex
                    Row(
                        Modifier.fillMaxWidth().clickable { vm.jumpToReadAlongClip(row); vm.showReadAloudSheet(false) }
                            .padding(vertical = Hearth.Spacing.S),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(

                            if (current) "▸ Clip ${row.index + 1}" else "Clip ${row.index + 1}",
                            style = if (current) HearthText.Body.copy(fontWeight = FontWeight.SemiBold) else HearthText.Body,
                            color = if (current) palette.ember else palette.text,
                            modifier = Modifier.weight(1f),
                        )
                        if (row.skippable) {
                            Text("Aside", style = HearthText.Overline, color = palette.textTertiary)
                            Spacer(Modifier.size(Hearth.Spacing.M))
                        }
                        Text(clipTime(row.startMs), style = HearthText.Caption, color = palette.textSecondary)
                    }
                }
            }
        }
    }
}

private fun clipTime(ms: Long): String {
    val totalSec = ms / 1000
    return "%d:%02d".format(totalSec / 60, totalSec % 60)
}

@Composable
private fun AppearanceSheet(vm: ReaderViewModel, state: ReaderUiState, customFonts: List<CustomFont>) {
    val palette = Hearth.palette
    val prefs = state.prefs
    Column(
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = Hearth.Spacing.XL)
            .padding(bottom = Hearth.Spacing.XXL),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
    ) {
        Overline("Theme")
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            ThemeCard("Paper", ReaderTheme.LIGHT, Color(0xFFFAF7F2), Color(0xFF231F1B), prefs.theme) { vm.updatePreferences(prefs.copy(theme = it)) }
            ThemeCard("Sepia", ReaderTheme.SEPIA, Color(0xFFEDD9B4), Color(0xFF4A3F30), prefs.theme) { vm.updatePreferences(prefs.copy(theme = it)) }
            ThemeCard("Ink", ReaderTheme.DARK, Color(0xFF191512), Color(0xFFF0E9DC), prefs.theme) { vm.updatePreferences(prefs.copy(theme = it)) }
            ThemeCard("Black", ReaderTheme.OLED, Color.Black, Color(0xFFF0E9DC), prefs.theme) { vm.updatePreferences(prefs.copy(theme = it)) }
        }

        Overline("Reader dimmer")
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            listOf(
                "Off" to -1f,
                "25%" to 0.75f,
                "50%" to 0.50f,
                "75%" to 0.25f,
            ).forEach { (label, value) ->
                val selected = if (value < 0f) prefs.screenBrightness < 0f
                else kotlin.math.abs(prefs.screenBrightness - value) < 0.01f
                HearthChip(label, selected = selected, onClick = { vm.updatePreferences(prefs.copy(screenBrightness = value)) })
            }
        }

        Overline("Status strip")
        ToggleRow("Show clock", prefs.showClock) { vm.updatePreferences(prefs.copy(showClock = it)) }
        ToggleRow("Show battery", prefs.showBattery) { vm.updatePreferences(prefs.copy(showBattery = it)) }
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            ReaderProgressDisplay.entries.forEach { mode ->
                HearthChip(mode.label, selected = prefs.progressDisplay == mode, onClick = { vm.updatePreferences(prefs.copy(progressDisplay = mode)) })
            }
        }

        Overline("Touch zones")
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            listOf(0.15f, 0.20f, 0.30f).forEach { width ->
                HearthChip(
                    "${(width * 100).toInt()}%",
                    selected = kotlin.math.abs(prefs.tapZoneWidth - width) < 0.01f,
                    onClick = { vm.updatePreferences(prefs.copy(tapZoneWidth = width)) },
                )
            }
        }
        ToggleRow("Left-edge brightness swipe", prefs.edgeBrightnessSwipe) {
            vm.updatePreferences(prefs.copy(edgeBrightnessSwipe = it))
        }

        Stepper("Text size", "${(prefs.fontSize * 100).roundToInt()}%",
            { vm.updatePreferences(prefs.copy(fontSize = (prefs.fontSize - READER_FONT_SCALE_STEP).coerceIn(MIN_READER_FONT_SCALE, MAX_READER_FONT_SCALE))) },
            { vm.updatePreferences(prefs.copy(fontSize = (prefs.fontSize + READER_FONT_SCALE_STEP).coerceIn(MIN_READER_FONT_SCALE, MAX_READER_FONT_SCALE))) })
        Stepper("Line height", "%.2f".format(prefs.lineHeight),
            { vm.updatePreferences(prefs.copy(lineHeight = (prefs.lineHeight - 0.05f).coerceIn(1.0f, 2.5f))) },
            { vm.updatePreferences(prefs.copy(lineHeight = (prefs.lineHeight + 0.05f).coerceIn(1.0f, 2.5f))) })
        Stepper("Margins", "%.1f".format(prefs.pageMargins),
            { vm.updatePreferences(prefs.copy(pageMargins = (prefs.pageMargins - 0.1f).coerceIn(0f, 2.0f))) },
            { vm.updatePreferences(prefs.copy(pageMargins = (prefs.pageMargins + 0.1f).coerceIn(0f, 2.0f))) })
        Stepper("Paragraph indent", "%.2f".format(prefs.paragraphIndent),
            { vm.updatePreferences(prefs.copy(paragraphIndent = (prefs.paragraphIndent - 0.25f).coerceIn(0f, 3f))) },
            { vm.updatePreferences(prefs.copy(paragraphIndent = (prefs.paragraphIndent + 0.25f).coerceIn(0f, 3f))) })

        Overline("Typeface")
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            ReaderFont.entries.forEach { f ->
                HearthChip(
                    f.displayName,
                    selected = f == prefs.font && prefs.customFontName == null,
                    onClick = { vm.updatePreferences(prefs.copy(font = f, customFontName = null)) },
                )
            }
            customFonts.forEach { font ->
                HearthChip(
                    font.displayName,
                    selected = prefs.customFontName == font.displayName,
                    onClick = { vm.updatePreferences(prefs.copy(customFontName = font.displayName)) },
                )
            }
        }

        Overline("Page flow")
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            HearthChip("Paged", selected = !prefs.scroll, onClick = { vm.updatePreferences(prefs.copy(scroll = false)) })
            HearthChip("Scrolled", selected = prefs.scroll, onClick = { vm.updatePreferences(prefs.copy(scroll = true)) })
        }

        ToggleRow("Justified text", prefs.justified) { vm.updatePreferences(prefs.copy(justified = it)) }
        ToggleRow("Respect publisher styles", prefs.publisherStyles) { vm.updatePreferences(prefs.copy(publisherStyles = it)) }
    }
}

@Composable
private fun ThemeCard(label: String, theme: ReaderTheme, bg: Color, fg: Color, current: ReaderTheme, onSelect: (ReaderTheme) -> Unit) {
    val palette = Hearth.palette
    val selected = theme == current
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(
            Modifier.size(width = 56.dp, height = 72.dp).clip(RoundedCornerShape(10.dp)).background(bg)
                .border(if (selected) 2.dp else 1.dp, if (selected) palette.ember else palette.hairline, RoundedCornerShape(10.dp))
                .clickable { onSelect(theme) },
            contentAlignment = Alignment.Center,
        ) {
            Text("Aa", style = hearthDisplay(20.sp, FontWeight.SemiBold), color = fg)
        }
        Text(label, style = HearthText.Overline, color = if (selected) palette.ember else palette.textSecondary)
    }
}

@Composable
private fun Stepper(label: String, value: String, onDec: () -> Unit, onInc: () -> Unit) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = HearthText.Body, color = palette.text)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.L)) {
            Text("-", style = HearthText.Body.copy(fontWeight = FontWeight.Bold, fontSize = 22.sp), color = palette.ember, modifier = Modifier.clip(CircleShape).clickable(onClick = onDec).padding(horizontal = Hearth.Spacing.S))
            Text(value, style = HearthText.Caption, color = palette.textSecondary)
            Text("+", style = HearthText.Body.copy(fontWeight = FontWeight.Bold, fontSize = 22.sp), color = palette.ember, modifier = Modifier.clip(CircleShape).clickable(onClick = onInc).padding(horizontal = Hearth.Spacing.S))
        }
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onCheck: (Boolean) -> Unit) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = HearthText.Body, color = palette.text)
        Switch(checked = checked, onCheckedChange = onCheck, colors = SwitchDefaults.colors(checkedTrackColor = palette.ember, checkedThumbColor = palette.readableOnEmber))
    }
}

@Composable
private fun ContentsSheet(vm: ReaderViewModel, state: ReaderUiState) {
    val palette = Hearth.palette
    var tab by remember { mutableIntStateOf(0) }
    var query by remember { mutableStateOf("") }
    val normalizedQuery = query.trim().lowercase()
    val filteredBookmarks = remember(state.bookmarks, normalizedQuery) {
        state.bookmarks.filter { it.matchesAnnotationQuery(normalizedQuery) }
    }
    val filteredNotes = remember(state.annotations, normalizedQuery) {
        state.annotations
            .filter { AnnotationKind.parse(it.kind) != AnnotationKind.BOOKMARK }
            .filter { it.matchesAnnotationQuery(normalizedQuery) }
    }
    val tocListState = rememberLazyListState()
    LaunchedEffect(tab, state.currentTocEntryId, state.tocEntries) {
        if (tab == 0) {
            val index = state.tocEntries.indexOfFirst { it.id == state.currentTocEntryId }
            if (index >= 0) tocListState.scrollToItem(index)
        }
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(bottom = Hearth.Spacing.XXL)) {
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XL), modifier = Modifier.padding(bottom = Hearth.Spacing.M)) {
            listOf("Contents", "Bookmarks", "Notes").forEachIndexed { i, label ->
                HearthChip(label, selected = i == tab, onClick = { tab = i })
            }
        }
        if (tab != 0) {
            SearchField(
                value = query,
                placeholder = if (tab == 1) "Search bookmarks..." else "Search notes...",
                onValueChange = { query = it },
            )
            Spacer(Modifier.size(Hearth.Spacing.S))
        }
        LazyColumn(Modifier.heightIn(max = 460.dp), state = tocListState) {
            when (tab) {
                0 -> if (state.tocEntries.isEmpty()) {
                    item { Empty("This book keeps no table of contents.") }
                } else {
                    items(state.tocEntries, key = { it.id }) { e ->
                        Text(
                            e.title,
                            style = hearthDisplay(16.sp, FontWeight.Normal),
                            color = if (e.id == state.currentTocEntryId) palette.ember else palette.text,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.fillMaxWidth().clickable { vm.navigateTo(e); vm.showToc(false) }
                                .padding(start = (e.depth * 16).dp, top = Hearth.Spacing.M, bottom = Hearth.Spacing.M),
                        )
                    }
                }
                1 -> if (filteredBookmarks.isEmpty()) {
                    item { Empty(if (query.isBlank()) "Nothing marked yet." else "No bookmarks match that search.") }
                } else {
                    items(filteredBookmarks, key = { it.id }) { a ->
                        AnnotationRow(
                            a = a,
                            dot = palette.ember,
                            onOpen = { vm.seekToAnnotation(a); vm.showToc(false) },
                            onEdit = { vm.showDecorationPopover(a.id); vm.showToc(false) },
                            onDelete = { vm.deleteAnnotation(a) },
                        )
                    }
                }
                2 -> if (filteredNotes.isEmpty()) {
                    item { Empty(if (query.isBlank()) "No notes or highlights yet." else "No notes match that search.") }
                } else {
                    items(filteredNotes, key = { it.id }) { a ->
                        AnnotationRow(
                            a = a,
                            dot = parseHex(a.colorHex),
                            onOpen = { vm.seekToAnnotation(a); vm.showToc(false) },
                            onEdit = { vm.showDecorationPopover(a.id); vm.showToc(false) },
                            onDelete = { vm.deleteAnnotation(a) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchField(value: String, placeholder: String, onValueChange: (String) -> Unit) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    Box(Modifier.fillMaxWidth().clip(shape).background(palette.bg).border(1.dp, palette.hairline, shape).padding(Hearth.Spacing.M)) {
        if (value.isEmpty()) Text(placeholder, style = HearthText.Body, color = palette.textTertiary)
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = HearthText.Body.copy(color = palette.text),
            cursorBrush = SolidColor(palette.ember),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun AnnotationRow(a: ReaderAnnotation, dot: Color, onOpen: () -> Unit, onEdit: () -> Unit, onDelete: () -> Unit) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(vertical = Hearth.Spacing.M), verticalAlignment = Alignment.Top) {
        Box(Modifier.size(10.dp).clip(CircleShape).background(dot).padding(top = 4.dp))
        Spacer(Modifier.size(Hearth.Spacing.M))
        Column(Modifier.weight(1f)) {
            Text(a.selectedText.ifBlank { a.note.ifBlank { "Bookmark" } }, style = HearthText.Body, color = palette.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
            if (a.note.isNotBlank() && a.selectedText.isNotBlank()) Text(a.note, style = HearthText.Caption, color = palette.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Text("Edit", style = HearthText.Caption, color = palette.ember, modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onEdit).padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.XS))
        Icon(Icons.Outlined.Delete, "Delete", tint = palette.textTertiary, modifier = Modifier.clip(CircleShape).clickable(onClick = onDelete).padding(Hearth.Spacing.XS).size(18.dp))
    }
}

private fun ReaderAnnotation.matchesAnnotationQuery(query: String): Boolean {
    if (query.isBlank()) return true
    return selectedText.contains(query, ignoreCase = true) ||
        note.contains(query, ignoreCase = true) ||
        chapterId.orEmpty().contains(query, ignoreCase = true) ||
        style.contains(query, ignoreCase = true) ||
        colorHex.contains(query, ignoreCase = true)
}

@Composable
private fun SearchSheet(vm: ReaderViewModel, state: ReaderUiState) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(bottom = Hearth.Spacing.XXL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        Box(Modifier.fillMaxWidth().clip(shape).background(palette.bg).border(1.dp, palette.hairline, shape).padding(Hearth.Spacing.M)) {
            if (state.searchQuery.isEmpty()) Text("Find in this book…", style = hearthDisplay(16.sp, FontWeight.Normal), color = palette.textTertiary)
            BasicTextField(
                value = state.searchQuery, onValueChange = vm::updateSearchQuery, singleLine = true,
                textStyle = hearthDisplay(16.sp, FontWeight.Normal).copy(color = palette.text),
                cursorBrush = SolidColor(palette.ember),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = { vm.runSearch() }),
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Search),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (state.searchLoading) Text("Searching…", style = HearthText.Caption, color = palette.textSecondary)
        state.searchError?.let { Text(it, style = HearthText.Caption, color = palette.statusError) }
        LazyColumn(Modifier.heightIn(max = 400.dp)) {
            items(state.searchResults) { r ->
                Column(
                    Modifier.fillMaxWidth().clickable { vm.seekToSearchResult(r); vm.showSearch(false) }.padding(vertical = Hearth.Spacing.M),
                ) {
                    Overline(r.title)
                    val text = r.locator.text
                    val emphasized = androidx.compose.ui.text.buildAnnotatedString {
                        append(text.before.orEmpty().replace(Regex("\\s+"), " ").takeLast(70))
                        withStyle(SpanStyle(color = palette.ember, fontWeight = FontWeight.SemiBold)) {
                            append(text.highlight.orEmpty().replace(Regex("\\s+"), " "))
                        }
                        append(text.after.orEmpty().replace(Regex("\\s+"), " ").take(90))
                    }
                    Text(emphasized, style = HearthText.Body, color = palette.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable
private fun Empty(text: String) {
    Text(text, style = HearthText.Body, color = Hearth.palette.textSecondary, modifier = Modifier.padding(vertical = Hearth.Spacing.L))
}
