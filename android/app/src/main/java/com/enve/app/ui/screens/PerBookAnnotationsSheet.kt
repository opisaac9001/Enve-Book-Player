package com.enve.app.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SecondaryTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.enve.app.data.export.AnnotationExportBook
import com.enve.app.data.export.AnnotationExporter
import com.enve.app.data.export.AnnotationFileFormat
import com.enve.app.data.export.AnnotationShareFiles
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.ReaderAnnotation
import com.enve.app.ui.components.AnnotationCard
import kotlinx.coroutines.launch
import java.io.IOException

private enum class AnnotationFilter { ALL, HIGHLIGHTS, NOTES, BOOKMARKS }
private enum class AnnotationSort { NEWEST, OLDEST, COLOR }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PerBookAnnotationsSheet(
    bookTitle: String,
    bookAuthor: String?,
    annotations: List<ReaderAnnotation>,
    onDismiss: () -> Unit,
    onJumpTo: (ReaderAnnotation) -> Unit,
    onEdit: (ReaderAnnotation) -> Unit,
    onDelete: (ReaderAnnotation) -> Unit,
    onSendToReadwise: (() -> Unit)? = null,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var filter by remember { mutableStateOf(AnnotationFilter.ALL) }
    var sort by remember { mutableStateOf(AnnotationSort.NEWEST) }
    var query by remember { mutableStateOf("") }
    var menuOpen by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val sendToReadwise = onSendToReadwise ?: (annotations.firstOrNull { !it.connectionUnresolved } ?: annotations.firstOrNull())?.let { owner ->
        { context.startActivity(ReadwiseActivity.createIntent(context, owner.bookId, owner.connectionId)) }
    }

    val filtered = remember(annotations, filter, query, sort) {
        annotations
            .asSequence()
            .filter { it.deletedAt == null }
            .filter {
                when (filter) {
                    AnnotationFilter.ALL        -> true
                    AnnotationFilter.HIGHLIGHTS -> AnnotationKind.parse(it.kind) == AnnotationKind.HIGHLIGHT
                    AnnotationFilter.NOTES      -> AnnotationKind.parse(it.kind) == AnnotationKind.NOTE
                    AnnotationFilter.BOOKMARKS  -> AnnotationKind.parse(it.kind) == AnnotationKind.BOOKMARK
                }
            }
            .filter {
                if (query.isBlank()) return@filter true
                val q = query.lowercase()
                it.selectedText.lowercase().contains(q) ||
                    it.note.lowercase().contains(q) ||
                    it.tagsJson.lowercase().contains(q)
            }
            .let { seq ->
                when (sort) {
                    AnnotationSort.NEWEST -> seq.sortedByDescending { it.updatedAt }
                    AnnotationSort.OLDEST -> seq.sortedBy { it.createdAt }
                    AnnotationSort.COLOR  -> seq.sortedBy { it.colorHex }
                }
            }
            .toList()
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.fillMaxWidth().heightIn(max = 600.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Notes & Highlights",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                Box {
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Default.IosShare, contentDescription = "Share / Export")
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        com.enve.app.ui.theme.RefreshEinkOnDismiss()
                        DropdownMenuItem(
                            text = { Text("Copy as Markdown") },
                            enabled = filtered.isNotEmpty(),
                            onClick = {
                                menuOpen = false
                                copyExport(context, filtered, bookTitle, bookAuthor)
                            },
                        )
                        AnnotationFileFormat.all.forEach { format ->
                            DropdownMenuItem(
                                text = { Text("Share as ${format.label}") },
                                enabled = filtered.isNotEmpty(),
                                onClick = {
                                    menuOpen = false
                                    val books = listOf(AnnotationExportBook(bookTitle, bookAuthor, filtered))
                                    scope.launch {
                                        try {
                                            AnnotationShareFiles.share(context, books, format, "$bookTitle highlights")
                                        } catch (_: IOException) {
                                            Toast.makeText(context, "Couldn't create the export file.", Toast.LENGTH_SHORT).show()
                                        }
                                    }
                                },
                            )
                        }
                        if (sendToReadwise != null) {
                            DropdownMenuItem(
                                text = { Text("Send to Readwise…") },
                                onClick = {
                                    menuOpen = false
                                    sendToReadwise()
                                },
                            )
                        }
                        DropdownMenuItem(
                            text = { Text("Sort: Newest") },
                            onClick = { sort = AnnotationSort.NEWEST; menuOpen = false },
                        )
                        DropdownMenuItem(
                            text = { Text("Sort: Oldest") },
                            onClick = { sort = AnnotationSort.OLDEST; menuOpen = false },
                        )
                        DropdownMenuItem(
                            text = { Text("Sort: Color") },
                            onClick = { sort = AnnotationSort.COLOR; menuOpen = false },
                        )
                    }
                }
            }

            SecondaryTabRow(selectedTabIndex = filter.ordinal) {
                AnnotationFilter.values().forEach { f ->
                    Tab(
                        selected = filter == f,
                        onClick = { filter = f },
                        text = { Text(f.label()) },
                    )
                }
            }

            TextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                placeholder = { Text("Search annotations") },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                singleLine = true,
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                ),
            )

            HorizontalDivider()

            if (filtered.isEmpty()) {
                Box(
                    modifier = Modifier.fillMaxWidth().padding(40.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "No annotations yet.\nSelect text to highlight, or add a bookmark from the chrome.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                LazyColumn(modifier = Modifier.fillMaxWidth()) {
                    items(filtered, key = { it.id }) { a ->
                        AnnotationCard(
                            annotation = a,
                            bookTitle = null,
                            onTap = { onJumpTo(a); onDismiss() },
                            onMore = { onEdit(a) },
                        )
                        HorizontalDivider()
                    }
                }
            }
        }
    }
}

private fun AnnotationFilter.label() = when (this) {
    AnnotationFilter.ALL -> "All"
    AnnotationFilter.HIGHLIGHTS -> "Highlights"
    AnnotationFilter.NOTES -> "Notes"
    AnnotationFilter.BOOKMARKS -> "Bookmarks"
}

private fun copyExport(
    context: Context,
    annotations: List<ReaderAnnotation>,
    bookTitle: String,
    bookAuthor: String?,
) {
    val text = AnnotationExporter.export(annotations, bookTitle, bookAuthor, AnnotationExporter.Format.MARKDOWN)
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText("Annotations", text))
}
