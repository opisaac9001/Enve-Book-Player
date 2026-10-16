package com.enve.hearth.detail

import com.enve.core.reader.highlightColorHex
import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.ReaderAnnotation
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.ShelfHeader
import com.enve.hearth.design.parseHexColor
import kotlin.math.roundToInt

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun AnnotationsSection(
    annotations: List<ReaderAnnotation>,
    filter: AnnotationFilter,
    query: String,
    tagsFor: (ReaderAnnotation) -> List<String>,
    onFilterChange: (AnnotationFilter) -> Unit,
    onQueryChange: (String) -> Unit,
    onJump: (ReaderAnnotation) -> Unit,
    onEdit: (ReaderAnnotation) -> Unit,
) {
    val palette = Hearth.palette
    val liveAnnotations = annotations.filter { it.deletedAt == null }
    val bookmarks = liveAnnotations.count { AnnotationKind.parse(it.kind) == AnnotationKind.BOOKMARK }
    val highlights = liveAnnotations.count { AnnotationKind.parse(it.kind) == AnnotationKind.HIGHLIGHT }
    val notes = liveAnnotations.count { AnnotationKind.parse(it.kind) == AnnotationKind.NOTE }
    val shown = liveAnnotations
        .filter { annotation ->
            when (filter) {
                AnnotationFilter.ALL -> true
                AnnotationFilter.BOOKMARKS -> AnnotationKind.parse(annotation.kind) == AnnotationKind.BOOKMARK
                AnnotationFilter.HIGHLIGHTS -> AnnotationKind.parse(annotation.kind) == AnnotationKind.HIGHLIGHT
                AnnotationFilter.NOTES -> AnnotationKind.parse(annotation.kind) == AnnotationKind.NOTE
            }
        }
        .filter { annotation ->
            val needle = query.trim()
            if (needle.isBlank()) true else {
                val haystack = listOf(
                    annotation.selectedText,
                    annotation.note,
                    annotation.chapterId.orEmpty(),
                    tagsFor(annotation).joinToString(" "),
                    annotationLocation(annotation),
                ).joinToString(" ").lowercase()
                haystack.contains(needle.lowercase())
            }
        }
        .sortedWith(compareByDescending<ReaderAnnotation> { it.updatedAt }.thenByDescending { it.createdAt })

    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.XL)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            ShelfHeader("Bookmarks & notes", modifier = Modifier.weight(1f))
            Text("${liveAnnotations.size}", style = HearthText.Caption, color = palette.textTertiary)
        }
        Spacer(Modifier.height(Hearth.Spacing.XS))
        Text(
            "$bookmarks bookmarks · $highlights highlights · $notes notes",
            style = HearthText.Caption,
            color = palette.textSecondary,
        )
        Spacer(Modifier.height(Hearth.Spacing.M))
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            AnnotationFilter.entries.forEach { f ->
                HearthChip(f.label, selected = filter == f, onClick = { onFilterChange(f) })
            }
        }
        Spacer(Modifier.height(Hearth.Spacing.M))
        OutlinedTextField(
            value = query,
            onValueChange = onQueryChange,
            label = { Text("Search marks") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(Hearth.Spacing.M))
        when {
            liveAnnotations.isEmpty() -> Text(
                "Bookmarks, highlights, and notes from the reader or player will appear here.",
                style = HearthText.Body,
                color = palette.textSecondary,
            )
            shown.isEmpty() -> Text(
                "No marks match this view.",
                style = HearthText.Body,
                color = palette.textSecondary,
            )
            else -> Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                shown.forEach { annotation ->
                    AnnotationRow(
                        annotation = annotation,
                        tags = tagsFor(annotation),
                        onJump = { onJump(annotation) },
                        onEdit = { onEdit(annotation) },
                    )
                }
            }
        }
    }
}

@Composable
private fun AnnotationRow(
    annotation: ReaderAnnotation,
    tags: List<String>,
    onJump: () -> Unit,
    onEdit: () -> Unit,
) {
    val palette = Hearth.palette
    val kind = AnnotationKind.parse(annotation.kind)
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier.fillMaxWidth()
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .clickable(onClick = onJump)
            .padding(Hearth.Spacing.M),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Box(
            Modifier.size(34.dp)
                .clip(CircleShape)
                .background(if (kind == AnnotationKind.HIGHLIGHT) annotationColor(annotation.colorHex) else palette.bg)
                .border(1.dp, palette.hairline, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(kind.label.take(1), style = HearthText.Label.copy(fontWeight = FontWeight.Bold), color = palette.text)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text(kind.label, style = HearthText.Caption.copy(fontWeight = FontWeight.SemiBold), color = palette.ember)
                Text(relativeTime(annotation.updatedAt), style = HearthText.Caption, color = palette.textTertiary)
            }
            annotation.selectedText.takeIf { it.isNotBlank() }?.let {
                Text(it, style = HearthText.Body, color = palette.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            annotation.note.takeIf { it.isNotBlank() }?.let {
                Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            val location = annotationLocation(annotation)
            if (location.isNotBlank()) Text(location, style = HearthText.Caption, color = palette.textTertiary)
            if (tags.isNotEmpty()) {
                Text(tags.joinToString(" · "), style = HearthText.Caption, color = palette.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Box(
            Modifier.heightIn(min = 48.dp).widthIn(min = 48.dp).clip(RoundedCornerShape(50))
                .clickable(role = Role.Button, onClickLabel = "Edit annotation", onClick = onEdit)
                .padding(horizontal = 8.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text("Edit", style = HearthText.Caption.copy(fontWeight = FontWeight.SemiBold), color = palette.ember)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun AnnotationEditDialog(
    annotation: ReaderAnnotation,
    currentTags: List<String>,
    knownTags: List<String>,
    onDismiss: () -> Unit,
    onJump: () -> Unit,
    onSave: (AnnotationStyle?, String?, String, List<String>) -> Unit,
    onDelete: () -> Unit,
) {
    val palette = Hearth.palette
    val kind = AnnotationKind.parse(annotation.kind)
    var note by remember(annotation.id) { mutableStateOf(annotation.note) }
    var tagsText by remember(annotation.id) { mutableStateOf(currentTags.joinToString(", ")) }
    var style by remember(annotation.id) { mutableStateOf(AnnotationStyle.parse(annotation.style)) }
    var colorHex by remember(annotation.id) { mutableStateOf(annotation.colorHex) }
    val parsedTags = parseTags(tagsText)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(kind.label) },
        text = {
            Column(
                Modifier.heightIn(max = 560.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
            ) {
                annotation.selectedText.takeIf { it.isNotBlank() }?.let {
                    Column(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(palette.bg)
                            .border(1.dp, palette.hairline, RoundedCornerShape(12.dp))
                            .padding(Hearth.Spacing.M),
                    ) {
                        Text(it, style = HearthText.Body, color = palette.text, maxLines = 6, overflow = TextOverflow.Ellipsis)
                    }
                }
                Text(annotationLocation(annotation), style = HearthText.Caption, color = palette.textTertiary)
                OutlinedTextField(
                    value = note,
                    onValueChange = { note = it.take(1500) },
                    label = { Text("Note") },
                    minLines = 4,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = tagsText,
                    onValueChange = { tagsText = it },
                    label = { Text("Tags") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                val tagSuggestions = knownTags.filter { it !in parsedTags }.take(10)
                if (tagSuggestions.isNotEmpty() || parsedTags.isNotEmpty()) {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                    ) {
                        parsedTags.forEach { tag ->
                            HearthChip("#$tag", selected = true, onClick = {
                                tagsText = (parsedTags - tag).joinToString(", ")
                            })
                        }
                        tagSuggestions.forEach { tag ->
                            HearthChip("#$tag", selected = false, onClick = {
                                tagsText = (parsedTags + tag).distinct().joinToString(", ")
                            })
                        }
                    }
                }
                if (kind == AnnotationKind.HIGHLIGHT) {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                    ) {
                        listOf(AnnotationStyle.HIGHLIGHT, AnnotationStyle.UNDERLINE, AnnotationStyle.STRIKETHROUGH, AnnotationStyle.SQUIGGLY).forEach { s ->
                            HearthChip(s.label, selected = style == s, onClick = { style = s })
                        }
                    }
                    FlowRow {
                        HighlightColors.forEach { (hex, name) ->
                            ColorSwatch(hex = hex, name = name, selected = colorHex.equals(hex, ignoreCase = true), onClick = { colorHex = hex })
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onSave(
                    if (kind == AnnotationKind.HIGHLIGHT) style else null,
                    if (kind == AnnotationKind.HIGHLIGHT) colorHex else null,
                    note.trim(),
                    parseTags(tagsText),
                )
            }) { Text("Save") }
        },
        dismissButton = {
            Row {
                TextButton(onClick = onDelete) { Text("Delete") }
                TextButton(onClick = onJump) { Text("Jump") }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

@Composable
private fun ColorSwatch(hex: String, name: String, selected: Boolean, onClick: () -> Unit) {
    val palette = Hearth.palette
    val shape = CircleShape
    Box(
        Modifier.size(48.dp)
            .clip(shape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .semantics { contentDescription = "$name highlight" },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(32.dp)
                .clip(shape)
                .background(annotationColor(hex))
                .border(if (selected) 3.dp else 1.dp, if (selected) palette.ember else palette.hairline, shape),
        )
    }
}

private val HighlightColors = listOf(
    "#FFF59D" to "Yellow",
    "#FFD166" to "Gold",
    "#F5921A" to "Orange",
    "#90CAF9" to "Blue",
    "#A5D6A7" to "Green",
    "#CE93D8" to "Purple",
)

private fun parseTags(text: String): List<String> =
    text.split(",")
        .map { it.trim().removePrefix("#") }
        .filter { it.isNotBlank() }
        .distinctBy { it.lowercase() }

private fun annotationLocation(annotation: ReaderAnnotation): String {
    val media = AnnotationMedia.parse(annotation.media)
    return when (media) {
        AnnotationMedia.AUDIOBOOK -> annotation.audioPositionMs?.let { fmtMillis(it) }
        AnnotationMedia.PDF -> annotation.pdfPage?.let { "Page ${it + 1}" }
        AnnotationMedia.CBZ -> annotation.cbzPage?.let { "Page ${it + 1}" }
        AnnotationMedia.EPUB -> annotation.totalProgression?.let { "${(it * 100).roundToInt()}%" }
    } ?: annotation.chapterId?.takeIf { it.isNotBlank() }
    ?: annotation.progression?.let { "${(it * 100).roundToInt()}%" }
    ?: media.name.lowercase().replaceFirstChar { it.titlecase() }
}

private fun fmtMillis(ms: Long): String {
    val sec = (ms / 1000).coerceAtLeast(0)
    val h = sec / 3600
    val m = (sec % 3600) / 60
    val s = sec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

private fun relativeTime(ms: Long): String =
    DateUtils.getRelativeTimeSpanString(ms, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()

private fun annotationColor(hex: String): Color = highlightColorHex(hex)?.let(::parseHexColor) ?: Color(0xFFFFF59D)
