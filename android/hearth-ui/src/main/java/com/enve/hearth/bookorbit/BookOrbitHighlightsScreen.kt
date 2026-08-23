package com.enve.hearth.bookorbit

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.DeleteForever
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.IosShare
import androidx.compose.material.icons.outlined.Restore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.engine.bookorbit.BookOrbitExportFormat
import com.enve.engine.bookorbit.BookOrbitHighlight
import com.enve.engine.bookorbit.BookOrbitHighlightBookFacet
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

@Composable
fun BookOrbitHighlightsScreen(
    onBack: () -> Unit,
    onOpenBook: (Book) -> Unit,
) {
    val vm: BookOrbitHighlightsViewModel = hiltViewModel()
    val accounts by vm.accounts.collectAsStateWithLifecycle()
    val accountId by vm.activeAccountId.collectAsStateWithLifecycle()
    val state by vm.state.collectAsStateWithLifecycle()
    val items by vm.items.collectAsStateWithLifecycle()
    val stats by vm.stats.collectAsStateWithLifecycle()
    val books by vm.books.collectAsStateWithLifecycle()
    val query by vm.query.collectAsStateWithLifecycle()
    val searchInput by vm.searchInput.collectAsStateWithLifecycle()
    val hasMore by vm.hasMore.collectAsStateWithLifecycle()
    val loadingMore by vm.loadingMore.collectAsStateWithLifecycle()
    val notice by vm.notice.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pendingDelete by remember { mutableStateOf<BookOrbitHighlight?>(null) }

    Box(Modifier.fillMaxSize()) {
        BookOrbitScreen(
            overline = "BookOrbit",
            title = "Highlights",
            accounts = accounts,
            selectedAccountId = accountId,
            onSelectAccount = vm::selectAccount,
            onBack = onBack,
            trailing = {
                ExportMenu { format ->
                    vm.export(format) { export ->
                        context.startActivity(
                            Intent.createChooser(
                                Intent(Intent.ACTION_SEND).apply {
                                    type = format.mimeType
                                    putExtra(Intent.EXTRA_SUBJECT, export.filename)
                                    putExtra(Intent.EXTRA_TEXT, export.content)
                                },
                                "Share highlights",
                            ),
                        )
                    }
                }
            },
        ) {
            Column(Modifier.weight(1f).fillMaxWidth()) {
                SearchField(searchInput, vm::setSearch)
                FilterRow(
                    trashed = query.trashed,
                    notesOnly = query.notesOnly,
                    selectedBookId = query.bookId,
                    books = books,
                    onTrashedChange = vm::setTrashed,
                    onNotesOnlyChange = vm::setNotesOnly,
                    onSelectBook = vm::selectBook,
                )
                when (state) {
                    BookOrbitLoad.Loading -> BookOrbitLoadingBlock()
                    BookOrbitLoad.NoAccount -> BookOrbitPlaceholder(
                        headline = "No BookOrbit account",
                        body = "Add a BookOrbit source to search every highlight your account holds.",
                    )
                    BookOrbitLoad.Unavailable -> BookOrbitPlaceholder(
                        headline = "Highlight hub unavailable",
                        body = "This BookOrbit server runs a build without the account-wide highlight API.",
                        onRetry = vm::retry,
                    )
                    BookOrbitLoad.Failed -> BookOrbitPlaceholder(
                        headline = "Couldn't reach BookOrbit",
                        body = "The server didn't answer. Check that the source is online and try again.",
                        onRetry = vm::retry,
                    )
                    is BookOrbitLoad.Ready -> if (items.isEmpty()) {
                        BookOrbitPlaceholder(
                            headline = if (query.trashed) "Trash is empty" else "No highlights match",
                            body = if (query.trashed) {
                                "Highlights you remove land here until you delete them for good."
                            } else {
                                "Try a different search, or clear the filters above."
                            },
                        )
                    } else {
                        HighlightList(
                            items = items,
                            trashed = query.trashed,
                            summary = "${stats.total} highlights · ${stats.books} books · ${stats.withNotes} with notes",
                            hasMore = hasMore,
                            loadingMore = loadingMore,
                            onLoadMore = vm::loadMore,
                            onOpenBook = { bookId -> scope.launch { vm.openBook(bookId)?.let(onOpenBook) } },
                            onTrash = vm::trash,
                            onRestore = vm::restore,
                            onDeleteForever = { pendingDelete = it },
                        )
                    }
                }
            }
        }

        notice?.let { message ->
            LaunchedEffect(message) {
                kotlinx.coroutines.delay(3_000)
                vm.dismissNotice()
            }
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .padding(Hearth.Spacing.XL)
                    .clip(RoundedCornerShape(999.dp))
                    .background(palette.bgElevated)
                    .border(1.dp, palette.hairline, RoundedCornerShape(999.dp))
                    .padding(horizontal = 18.dp, vertical = 10.dp),
            ) {
                Text(message, style = HearthText.Caption, color = palette.text)
            }
        }
    }

    pendingDelete?.let { highlight ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete permanently?") },
            text = { Text("This removes the highlight from BookOrbit and every synced device. It can't be undone.") },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    vm.deleteForever(highlight)
                    pendingDelete = null
                }) { Text("Delete") }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            },
            containerColor = palette.bgElevated,
            titleContentColor = palette.text,
            textContentColor = palette.textSecondary,
        )
    }
}

@Composable
private fun ExportMenu(onExport: (BookOrbitExportFormat) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val palette = Hearth.palette
    Box {
        Box(
            Modifier
                .size(48.dp)
                .clip(CircleShape)
                .clickable { expanded = true },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Outlined.IosShare,
                contentDescription = "Export highlights",
                tint = palette.text,
                modifier = Modifier.size(22.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            BookOrbitExportFormat.entries.forEach { format ->
                DropdownMenuItem(
                    text = { Text(format.name.lowercase().replaceFirstChar { it.uppercase() }) },
                    onClick = {
                        expanded = false
                        onExport(format)
                    },
                )
            }
        }
    }
}

@Composable
private fun SearchField(value: String, onValueChange: (String) -> Unit) {
    val palette = Hearth.palette
    TextField(
        value = value,
        onValueChange = onValueChange,
        placeholder = { Text("Search highlights and notes", style = HearthText.Body) },
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.S),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = palette.bgElevated,
            unfocusedContainerColor = palette.bgElevated,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            focusedTextColor = palette.text,
            unfocusedTextColor = palette.text,
            cursorColor = palette.ember,
            focusedPlaceholderColor = palette.textTertiary,
            unfocusedPlaceholderColor = palette.textTertiary,
        ),
        shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Inner),
    )
}

@Composable
private fun FilterRow(
    trashed: Boolean,
    notesOnly: Boolean,
    selectedBookId: Int?,
    books: List<BookOrbitHighlightBookFacet>,
    onTrashedChange: (Boolean) -> Unit,
    onNotesOnlyChange: (Boolean) -> Unit,
    onSelectBook: (Int?) -> Unit,
) {
    LazyRow(
        contentPadding = PaddingValues(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.XS),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        item { HearthChip("Library", !trashed, onClick = { onTrashedChange(false) }) }
        item { HearthChip("Trash", trashed, onClick = { onTrashedChange(true) }) }
        item { HearthChip("With notes", notesOnly, onClick = { onNotesOnlyChange(!notesOnly) }) }
        item { HearthChip("All books", selectedBookId == null, onClick = { onSelectBook(null) }) }
        items(books, key = { it.bookId }) { facet ->
            HearthChip(
                label = "${facet.title} (${facet.count})",
                selected = facet.bookId == selectedBookId,
                onClick = { onSelectBook(if (facet.bookId == selectedBookId) null else facet.bookId) },
            )
        }
    }
}

@Composable
private fun HighlightList(
    items: List<BookOrbitHighlight>,
    trashed: Boolean,
    summary: String,
    hasMore: Boolean,
    loadingMore: Boolean,
    onLoadMore: () -> Unit,
    onOpenBook: (Int) -> Unit,
    onTrash: (BookOrbitHighlight) -> Unit,
    onRestore: (BookOrbitHighlight) -> Unit,
    onDeleteForever: (BookOrbitHighlight) -> Unit,
) {
    val listState = rememberLazyListState()
    val nearEnd by remember {
        derivedStateOf {
            val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= listState.layoutInfo.totalItemsCount - 4
        }
    }
    LaunchedEffect(nearEnd, hasMore) {
        if (nearEnd && hasMore) onLoadMore()
    }

    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            start = Hearth.Spacing.XL,
            top = Hearth.Spacing.S,
            end = Hearth.Spacing.XL,
            bottom = Hearth.Spacing.XXL,
        ),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        item {
            Text(summary, style = HearthText.Caption, color = Hearth.palette.textTertiary)
        }
        items(items, key = { it.id }) { highlight ->
            HighlightCard(
                highlight = highlight,
                trashed = trashed,
                onOpenBook = onOpenBook,
                onTrash = onTrash,
                onRestore = onRestore,
                onDeleteForever = onDeleteForever,
            )
        }
        if (loadingMore) {
            item { BookOrbitLoadingBlock() }
        }
    }
}

@Composable
private fun HighlightCard(
    highlight: BookOrbitHighlight,
    trashed: Boolean,
    onOpenBook: (Int) -> Unit,
    onTrash: (BookOrbitHighlight) -> Unit,
    onRestore: (BookOrbitHighlight) -> Unit,
    onDeleteForever: (BookOrbitHighlight) -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else Hearth.Radius.Card)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .clickable { onOpenBook(highlight.bookId) }
            .padding(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            Box(
                Modifier
                    .width(4.dp)
                    .height(44.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(if (eink.active) palette.text else parseColor(highlight.colorHex, palette.ember)),
            )
            Text(
                highlight.text,
                style = HearthText.Body,
                color = palette.text,
                maxLines = 6,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
        }
        highlight.note?.let {
            Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 4, overflow = TextOverflow.Ellipsis)
        }
        Text(
            listOfNotNull(
                highlight.bookTitle ?: "Untitled",
                highlight.author,
                highlight.chapterTitle,
                highlight.origin?.originLabel(),
                highlight.createdAtMs?.let { DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(it)) },
            ).joinToString(" · "),
            style = HearthText.Caption,
            color = palette.textTertiary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            if (trashed) {
                HighlightAction(Icons.Outlined.Restore, "Restore") { onRestore(highlight) }
                HighlightAction(Icons.Outlined.DeleteForever, "Delete permanently") { onDeleteForever(highlight) }
            } else {
                HighlightAction(Icons.Outlined.DeleteOutline, "Move to trash") { onTrash(highlight) }
            }
        }
    }
}

@Composable
private fun HighlightAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    val shape = if (Hearth.eink.sharpCorners) RoundedCornerShape(0.dp) else RoundedCornerShape(50)
    Row(
        Modifier
            .clip(shape)
            .border(1.dp, palette.hairline, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
    ) {
        Icon(icon, contentDescription = null, tint = palette.textSecondary, modifier = Modifier.size(16.dp))
        Text(label, style = HearthText.Caption.copy(fontWeight = FontWeight.Medium), color = palette.textSecondary)
    }
}

private fun String.originLabel(): String = when (lowercase()) {
    "koreader" -> "KOReader"
    "kobo" -> "Kobo"
    "web" -> "BookOrbit"
    else -> replaceFirstChar { it.uppercase() }
}

private fun parseColor(hex: String, fallback: Color): Color {
    val cleaned = hex.trim().removePrefix("#")
    val expanded = if (cleaned.length == 3) cleaned.map { "$it$it" }.joinToString("") else cleaned
    if (expanded.length != 6) return fallback
    val value = expanded.toLongOrNull(16) ?: return fallback
    return Color(0xFF000000 or value)
}
