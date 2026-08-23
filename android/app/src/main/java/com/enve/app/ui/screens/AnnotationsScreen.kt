package com.enve.app.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.StickyNote2
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FormatStrikethrough
import androidx.compose.material.icons.filled.FormatUnderlined
import androidx.compose.material.icons.filled.Highlight
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Waves
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import coil.compose.AsyncImage
import com.enve.app.data.export.AnnotationExporter
import com.enve.app.ui.components.AnnotationEditSheet
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.EnveTheme
import com.enve.hearth.design.hearthDisplay
import com.enve.app.viewmodel.AnnotationBookSection
import com.enve.app.viewmodel.AnnotationsViewModel
import com.enve.app.viewmodel.HighlightFilter
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import java.text.DateFormat
import java.util.Date
import kotlin.math.roundToInt

@Composable
fun AnnotationsScreen(
    onBack: () -> Unit = {},
    onOpenAnnotation: (Book, ReaderAnnotation) -> Unit = { _, _ -> },
    vm: AnnotationsViewModel = hiltViewModel(),
) {
    val colors = EnveTheme.colors
    val state by vm.state.collectAsState()
    val sections = vm.visibleSections()
    val visibleAnnotations = vm.visibleAnnotations()
    val context = LocalContext.current
    val snackbarHostState = remember { SnackbarHostState() }
    var editing by remember { mutableStateOf<ReaderAnnotation?>(null) }
    var menuOpen by remember { mutableStateOf(false) }

    LaunchedEffect(state.undoableDelete?.id) {
        val pending = state.undoableDelete ?: return@LaunchedEffect
        val result = snackbarHostState.showSnackbar(
            message = "Deleted ${pending.selectedText.take(40).ifBlank { "annotation" }}",
            actionLabel = "Undo",
            withDismissAction = true,
        )
        if (result == SnackbarResult.ActionPerformed) vm.undoDelete()
    }

    Scaffold(
        containerColor = colors.background,
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = onBack)
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = 12.dp),
                ) {
                    Text("Highlights", color = colors.primaryText, style = hearthDisplay(22.sp))
                    Text(
                        text = "${visibleAnnotations.size} saved",
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.secondaryText,
                    )
                }
                Box {
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Default.IosShare, contentDescription = "Share / Export", tint = colors.primaryText)
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        com.enve.app.ui.theme.RefreshEinkOnDismiss()
                        DropdownMenuItem(
                            text = { Text("Copy filtered as Markdown") },
                            enabled = visibleAnnotations.isNotEmpty(),
                            onClick = {
                                menuOpen = false
                                copy(context, visibleAnnotations, AnnotationExporter.Format.MARKDOWN)
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Share as Markdown") },
                            enabled = visibleAnnotations.isNotEmpty(),
                            onClick = {
                                menuOpen = false
                                share(context, visibleAnnotations, AnnotationExporter.Format.MARKDOWN)
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Share as JSON") },
                            enabled = visibleAnnotations.isNotEmpty(),
                            onClick = {
                                menuOpen = false
                                share(context, visibleAnnotations, AnnotationExporter.Format.JSON)
                            },
                        )
                    }
                }
            }

            HighlightsSearchBar(
                query = state.query,
                onQueryChange = vm::setQuery,
                onClear = { vm.setQuery("") },
            )
            HighlightFilterChips(
                selected = state.filter,
                onSelect = vm::setFilter,
            )

            HorizontalDivider(color = colors.separator)

            if (sections.isEmpty()) {
                HighlightsEmptyState(
                    isLoading = state.isLoading,
                    hasFilters = state.query.isNotBlank() || state.filter != HighlightFilter.ALL,
                    onClearFilters = vm::clearFilters,
                )
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(bottom = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(sections, key = { it.bookId }) { section ->
                        HighlightBookSection(
                            section = section,
                            onOpen = { annotation ->
                                section.book?.let { onOpenAnnotation(it, annotation) }
                            },
                            onEdit = { editing = it },
                        )
                    }
                }
            }
        }
    }

    val editingAnnotation = editing
    if (editingAnnotation != null) {
        val knownTags by vm.knownTags.collectAsState()
        AnnotationEditSheet(
            annotation = editingAnnotation,
            initialTags = vm.tagsFor(editingAnnotation),
            onDismiss = { editing = null },
            onSave = { style, color, note, tags ->
                vm.update(editingAnnotation, style, color, note, tags)
                editing = null
            },
            onDelete = {
                vm.delete(editingAnnotation)
                editing = null
            },
            knownTags = knownTags,
        )
    }
}

@Composable
private fun HighlightsSearchBar(
    query: String,
    onQueryChange: (String) -> Unit,
    onClear: () -> Unit,
) {
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        placeholder = { Text("Search highlights...") },
        leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
        trailingIcon = {
            if (query.isNotBlank()) {
                IconButton(onClick = onClear) {
                    Icon(Icons.Default.Close, contentDescription = "Clear search")
                }
            }
        },
        singleLine = true,
    )
}

@Composable
private fun HighlightFilterChips(
    selected: HighlightFilter,
    onSelect: (HighlightFilter) -> Unit,
) {
    LazyRow(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, bottom = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(HighlightFilter.entries) { filter ->
            FilterChip(
                selected = selected == filter,
                onClick = { onSelect(filter) },
                leadingIcon = filter.icon()?.let { icon ->
                    { Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp)) }
                },
                label = { Text(filter.label) },
            )
        }
    }
}

@Composable
private fun HighlightBookSection(
    section: AnnotationBookSection,
    onOpen: (ReaderAnnotation) -> Unit,
    onEdit: (ReaderAnnotation) -> Unit,
) {
    val colors = EnveTheme.colors
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp),
        shape = RoundedCornerShape(22.dp),
        color = colors.cardBackground,
        border = if (EnveTheme.isEink) null else BorderStroke(0.5.dp, Color.White.copy(alpha = 0.08f)),
    ) {
        Column(modifier = Modifier.padding(vertical = 12.dp)) {
            Row(
                modifier = Modifier.padding(horizontal = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                HighlightBookCover(section.coverUrl, section.title)
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        text = section.title,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.primaryText,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    section.author?.takeIf { it.isNotBlank() }?.let {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.secondaryText,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                AssistChip(
                    onClick = {},
                    enabled = false,
                    label = { Text(section.annotations.size.toString()) },
                    colors = AssistChipDefaults.assistChipColors(
                        disabledLabelColor = colors.accent,
                        disabledContainerColor = colors.accent.copy(alpha = 0.10f),
                    ),
                )
            }

            HorizontalDivider(
                modifier = Modifier.padding(top = 12.dp),
                color = colors.separator,
            )

            section.annotations.forEachIndexed { index, annotation ->
                if (index > 0) {
                    HorizontalDivider(color = colors.separator.copy(alpha = 0.65f))
                }
                HighlightRow(
                    annotation = annotation,
                    canOpen = section.book != null,
                    onOpen = { onOpen(annotation) },
                    onEdit = { onEdit(annotation) },
                )
            }
        }
    }
}

@Composable
private fun HighlightBookCover(coverUrl: String?, title: String) {
    Box(
        modifier = Modifier
            .size(width = 42.dp, height = 56.dp)
            .clip(RoundedCornerShape(7.dp))
            .background(EnveTheme.colors.secondaryBackground),
        contentAlignment = Alignment.Center,
    ) {
        if (!coverUrl.isNullOrBlank()) {
            AsyncImage(
                model = coverUrl,
                contentDescription = "$title cover",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        } else {
            Text(
                text = title.firstOrNull()?.uppercaseChar()?.toString().orEmpty(),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = EnveTheme.colors.tertiaryText,
            )
        }
    }
}

@Composable
private fun HighlightRow(
    annotation: ReaderAnnotation,
    canOpen: Boolean,
    onOpen: () -> Unit,
    onEdit: () -> Unit,
) {
    val colors = EnveTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = canOpen, onClick = onOpen)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier
                .padding(top = 4.dp)
                .size(10.dp)
                .clip(CircleShape)
                .background(colorFromHex(annotation.colorHex)),
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(
                    imageVector = annotation.icon(),
                    contentDescription = null,
                    modifier = Modifier.size(15.dp),
                    tint = colors.secondaryText,
                )
                Text(
                    text = annotation.label(),
                    style = MaterialTheme.typography.labelSmall,
                    color = colors.secondaryText,
                )
                annotation.progressLabel()?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.tertiaryText,
                    )
                }
            }

            val body = annotation.selectedText.ifBlank { annotation.note.ifBlank { "Note" } }
            Text(
                text = body,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                color = colors.primaryText,
                maxLines = 6,
                overflow = TextOverflow.Ellipsis,
            )

            if (annotation.selectedText.isNotBlank() && annotation.note.isNotBlank()) {
                Text(
                    text = annotation.note,
                    style = MaterialTheme.typography.bodySmall,
                    color = EnveTheme.colors.secondaryText,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(EnveTheme.colors.secondaryBackground)
                        .padding(horizontal = 10.dp, vertical = 7.dp),
                )
            }

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                annotation.chapterId?.takeIf { it.isNotBlank() }?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.accent,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                }
                Text(
                    text = formatDate(annotation.updatedAt),
                    style = MaterialTheme.typography.labelSmall,
                    color = colors.secondaryText,
                )
            }
        }
        IconButton(onClick = onEdit, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Default.MoreVert, contentDescription = "Edit annotation", tint = colors.secondaryText)
        }
    }
}

@Composable
private fun HighlightsEmptyState(
    isLoading: Boolean,
    hasFilters: Boolean,
    onClearFilters: () -> Unit,
) {
    val colors = EnveTheme.colors
    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(
                Icons.Default.Highlight,
                contentDescription = null,
                tint = colors.secondaryText,
                modifier = Modifier.size(42.dp),
            )
            Text(
                text = when {
                    isLoading -> "Loading highlights..."
                    hasFilters -> "No results"
                    else -> "No highlights yet"
                },
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = colors.primaryText,
            )
            Text(
                text = if (hasFilters) {
                    "Try changing the search or filter."
                } else {
                    "Highlights, underlines, squiggles, strikes, and notes from ebooks appear here."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = colors.secondaryText,
            )
            if (hasFilters) {
                AssistChip(onClick = onClearFilters, label = { Text("Clear filters") })
            }
        }
    }
}

private fun HighlightFilter.icon(): ImageVector? = when (this) {
    HighlightFilter.ALL -> null
    HighlightFilter.HIGHLIGHTS -> Icons.Default.Highlight
    HighlightFilter.UNDERLINES -> Icons.Default.FormatUnderlined
    HighlightFilter.SQUIGGLES -> Icons.Default.Waves
    HighlightFilter.STRIKES -> Icons.Default.FormatStrikethrough
    HighlightFilter.NOTES -> Icons.AutoMirrored.Filled.StickyNote2
}

private fun ReaderAnnotation.icon(): ImageVector = when (AnnotationKind.parse(kind)) {
    AnnotationKind.NOTE -> Icons.AutoMirrored.Filled.StickyNote2
    AnnotationKind.BOOKMARK -> Icons.AutoMirrored.Filled.StickyNote2
    AnnotationKind.HIGHLIGHT -> when (AnnotationStyle.parse(style)) {
        AnnotationStyle.UNDERLINE -> Icons.Default.FormatUnderlined
        AnnotationStyle.STRIKETHROUGH -> Icons.Default.FormatStrikethrough
        AnnotationStyle.SQUIGGLY -> Icons.Default.Waves
        AnnotationStyle.HIGHLIGHT,
        AnnotationStyle.NONE -> Icons.Default.Highlight
    }
}

private fun ReaderAnnotation.label(): String = when (AnnotationKind.parse(kind)) {
    AnnotationKind.NOTE -> "Note"
    AnnotationKind.BOOKMARK -> "Bookmark"
    AnnotationKind.HIGHLIGHT -> AnnotationStyle.parse(style).label
}

private fun ReaderAnnotation.progressLabel(): String? {
    val progress = totalProgression ?: progression ?: return null
    return "${(progress * 100.0).roundToInt().coerceIn(0, 100)}%"
}

private fun colorFromHex(hex: String): Color =
    runCatching { Color(android.graphics.Color.parseColor(hex)) }
        .getOrDefault(Color(0xFFFFF59D))

private fun formatDate(timestamp: Long): String =
    DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(timestamp))

private fun copy(context: Context, list: List<ReaderAnnotation>, format: AnnotationExporter.Format) {
    val text = AnnotationExporter.export(list, null, null, format)
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("Highlights", text))
}

private fun share(context: Context, list: List<ReaderAnnotation>, format: AnnotationExporter.Format) {
    val text = AnnotationExporter.export(list, null, null, format)
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = AnnotationExporter.mimeType(format)
        putExtra(Intent.EXTRA_SUBJECT, "Highlights")
        putExtra(Intent.EXTRA_TEXT, text)
    }
    context.startActivity(Intent.createChooser(intent, "Share highlights"))
}
