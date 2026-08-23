package com.enve.app.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FormatColorFill
import androidx.compose.material.icons.filled.FormatStrikethrough
import androidx.compose.material.icons.filled.FormatUnderlined
import androidx.compose.material.icons.filled.Brush
import androidx.compose.material.icons.filled.Tag
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.ReaderAnnotation

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AnnotationEditSheet(
    annotation: ReaderAnnotation,
    initialTags: List<String>,
    onDismiss: () -> Unit,
    onSave: (style: AnnotationStyle, colorHex: String, note: String, tags: List<String>) -> Unit,
    onDelete: () -> Unit,
    onJumpTo: (() -> Unit)? = null,

    knownTags: List<String> = emptyList(),
) {

    val maxNoteChars = 1500
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var style by remember { mutableStateOf(AnnotationStyle.parse(annotation.style)) }
    var colorHex by remember { mutableStateOf(annotation.colorHex) }
    var note by remember { mutableStateOf(annotation.note) }
    var tags by remember { mutableStateOf(initialTags) }
    var tagDraft by remember { mutableStateOf("") }
    val kind = AnnotationKind.parse(annotation.kind)

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .imePadding()
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                when (kind) {
                    AnnotationKind.HIGHLIGHT -> "Edit highlight"
                    AnnotationKind.NOTE      -> "Edit note"
                    AnnotationKind.BOOKMARK  -> "Edit bookmark"
                },
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )

            if (annotation.selectedText.isNotBlank()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .padding(8.dp),
                ) {
                    Text(
                        text = "“${annotation.selectedText}”",
                        style = MaterialTheme.typography.bodyMedium,
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (kind == AnnotationKind.HIGHLIGHT) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Color", style = MaterialTheme.typography.labelMedium)
                    ColorSwatchRow(
                        selectedHex = colorHex,
                        onSelect = { colorHex = it },
                        contrast = MaterialTheme.colorScheme.onSurface,
                    )
                }

                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Style", style = MaterialTheme.typography.labelMedium)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        StyleChip("Highlight", style == AnnotationStyle.HIGHLIGHT) {
                            style = AnnotationStyle.HIGHLIGHT
                        }
                        StyleChip("Underline", style == AnnotationStyle.UNDERLINE) {
                            style = AnnotationStyle.UNDERLINE
                        }
                        StyleChip("Strike", style == AnnotationStyle.STRIKETHROUGH) {
                            style = AnnotationStyle.STRIKETHROUGH
                        }
                        StyleChip("Squiggle", style == AnnotationStyle.SQUIGGLY) {
                            style = AnnotationStyle.SQUIGGLY
                        }
                    }
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Note", style = MaterialTheme.typography.labelMedium, modifier = Modifier.weight(1f))
                    val remaining = maxNoteChars - note.length
                    Text(
                        "$remaining",
                        style = MaterialTheme.typography.labelSmall,
                        color = if (remaining < 0) MaterialTheme.colorScheme.error
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                TextField(
                    value = note,
                    onValueChange = { input -> if (input.length <= maxNoteChars) note = input },
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 80.dp),
                    placeholder = { Text("Add a note (markdown supported)") },
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                        unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                    ),
                )
            }

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Tags", style = MaterialTheme.typography.labelMedium)
                if (tags.isNotEmpty()) {
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        items(tags) { tag ->
                            AssistChip(
                                onClick = { tags = tags - tag },
                                label = { Text(tag) },
                                leadingIcon = { Icon(Icons.Default.Tag, null, modifier = Modifier.size(14.dp)) },
                            )
                        }
                    }
                }
                TextField(
                    value = tagDraft,
                    onValueChange = { input ->
                        if (input.endsWith(",") || input.endsWith(" ")) {
                            val t = input.trimEnd(',', ' ').trim()
                            if (t.isNotBlank() && t !in tags) tags = tags + t
                            tagDraft = ""
                        } else tagDraft = input
                    },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("Add tag, press space or comma") },
                    singleLine = true,
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                        unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                    ),
                )

                val suggestions = remember(tagDraft, tags, knownTags) {
                    val q = tagDraft.trim().lowercase()
                    val pool = knownTags.filter { it !in tags }
                    val ranked = if (q.isEmpty()) pool
                        else pool.filter { it.lowercase().startsWith(q) } +
                             pool.filter { !it.lowercase().startsWith(q) && it.lowercase().contains(q) }
                    ranked.distinct().take(8)
                }
                if (suggestions.isNotEmpty()) {
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        items(suggestions) { suggestion ->
                            AssistChip(
                                onClick = { tags = tags + suggestion; tagDraft = "" },
                                label = { Text(suggestion) },
                            )
                        }
                    }
                }
            }

            HorizontalDivider()

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedButton(onClick = onDelete) {
                    Icon(Icons.Default.Delete, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Delete")
                }
                Spacer(Modifier.weight(1f))
                if (onJumpTo != null) {
                    TextButton(onClick = onJumpTo) { Text("Jump to") }
                }
                Button(onClick = { onSave(style, colorHex, note, tags) }) {
                    Text("Save")
                }
            }
        }
    }
}

@Composable
private fun StyleChip(label: String, selected: Boolean, onClick: () -> Unit) {
    if (selected) {
        FilledTonalButton(onClick = onClick, modifier = Modifier.height(36.dp)) {
            Text(label, fontSize = 12.sp)
        }
    } else {
        OutlinedButton(onClick = onClick, modifier = Modifier.height(36.dp)) {
            Text(label, fontSize = 12.sp)
        }
    }
}
