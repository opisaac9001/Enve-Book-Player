package com.enve.hearth.library

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
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
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.hearthDisplay
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

@Composable
internal fun BookGrid(
    books: List<Book>,
    columns: Int,
    vm: HearthLibraryViewModel,
    selectionMode: Boolean,
    selection: Set<String>,
    onOpen: (Book) -> Unit,
    onPlay: (Book) -> Unit,
    onRemove: ((Book) -> Unit)? = null,
    hasLibraryBooks: Boolean = true,
    onAddSource: (() -> Unit)? = null,
) {
    val eink = Hearth.eink
    val listLayout = eink.denseListLibrary || columns == 1
    if (books.isEmpty()) {
        EmptyLibraryState(hasLibraryBooks, onAddSource)
        return
    }
    LazyVerticalGrid(
        columns = if (listLayout) GridCells.Fixed(1) else GridCells.Fixed(columns.coerceIn(2, 4)),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = Hearth.Spacing.XL, end = Hearth.Spacing.XL,
            top = 0.dp, bottom = LocalMantelInset.current + Hearth.Spacing.L,
        ),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        modifier = Modifier.fillMaxSize(),
    ) {
        items(books, key = { it.id + (it.connectionId ?: "") }) { book ->
            if (listLayout) {
                DenseBookRow(
                    book = book,
                    vm = vm,
                    selectionMode = selectionMode,
                    selected = book.uniqueKey in selection,
                    onOpen = onOpen,
                    onPlay = onPlay,
                    onRemove = onRemove,
                )
            } else {
                GridCoverCell(book, vm, selectionMode, selected = book.uniqueKey in selection, onOpen, onPlay, onRemove)
            }
        }
    }
}

@Composable
private fun EmptyLibraryState(hasLibraryBooks: Boolean, onAddSource: (() -> Unit)?) {
    val palette = Hearth.palette
    Column(
        Modifier.fillMaxSize().padding(horizontal = Hearth.Spacing.XL),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            if (hasLibraryBooks) "Nothing matches this filter." else "Your library is empty.",
            style = hearthDisplay(22.sp, FontWeight.Bold),
            color = palette.text,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        Spacer(Modifier.size(Hearth.Spacing.S))
        Text(
            if (hasLibraryBooks) "Your shelves aren't empty. A filter is just hiding them."
            else "Connect a source or import books to get started.",
            style = HearthText.Body,
            color = palette.textSecondary,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        if (!hasLibraryBooks && onAddSource != null) {
            Spacer(Modifier.size(Hearth.Spacing.M))
            Button(onClick = onAddSource) { Text("Add a source") }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GridCoverCell(
    book: Book,
    vm: HearthLibraryViewModel,
    selectionMode: Boolean,
    selected: Boolean,
    onOpen: (Book) -> Unit,
    onPlay: (Book) -> Unit,
    onRemove: ((Book) -> Unit)? = null,
) {
    val palette = Hearth.palette
    var menu by remember { mutableStateOf(false) }
    var pendingAction by remember(book.uniqueKey) { mutableStateOf<BookCardDestructiveAction?>(null) }
    Column(
        Modifier
            .fillMaxWidth()
            .combinedClickable(
                onClick = { if (selectionMode) vm.toggleSelected(book) else onOpen(book) },
                onLongClick = { if (!selectionMode) menu = true },
            ),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .then(if (selected) Modifier.border(2.dp, palette.ember, RoundedCornerShape(Hearth.Radius.Inner)) else Modifier),
        ) {
            CoverTile(
                model = book.coverUrl,
                mediaType = book.mediaType,
                modifier = Modifier.fillMaxWidth(),
                contentDescription = book.title,
                progress = com.enve.hearth.design.HearthFormat.progress(book),
                isFinished = book.isFinished,
            )
            if (selected) {
                Icon(
                    Icons.Filled.CheckCircle, contentDescription = "Selected", tint = palette.ember,
                    modifier = Modifier.align(Alignment.TopStart).padding(6.dp).size(22.dp),
                )
            }
            if (book.isDownloaded) {
                Icon(
                    Icons.Outlined.Download,
                    contentDescription = "Downloaded",
                    tint = palette.text,
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(6.dp)
                        .clip(CircleShape)
                        .background(palette.bg.copy(alpha = 0.78f))
                        .padding(5.dp)
                        .size(16.dp),
                )
            }
        }
        Spacer(Modifier.size(6.dp))
        Text(book.title, style = hearthDisplay(14.sp, FontWeight.SemiBold), color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
        book.author?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            val listen = isAudioPlayable(book)
            DropdownMenuItem(text = { Text(if (listen) "Play" else "Read") }, onClick = { menu = false; onPlay(book) })
            if (listen) {
                DropdownMenuItem(text = { Text("Play next") }, onClick = { menu = false; vm.addNext(book) })
                DropdownMenuItem(text = { Text("Add to Up Next") }, onClick = { menu = false; vm.addLast(book) })
            }
            DropdownMenuItem(
                text = { Text(if (book.isFinished) "Mark unfinished" else "Mark finished") },
                onClick = { menu = false; vm.setFinished(book, !book.isFinished) },
            )
            if (book.source != BookSource.LOCAL) {
                if (book.isDownloaded) {
                    DropdownMenuItem(text = { Text("Remove download") }, onClick = { menu = false; pendingAction = BookCardDestructiveAction.REMOVE_DOWNLOAD })
                } else {
                    DropdownMenuItem(text = { Text("Download") }, onClick = { menu = false; vm.download(book) })
                }
            }
            DropdownMenuItem(text = { Text("Hide from library") }, onClick = { menu = false; pendingAction = BookCardDestructiveAction.HIDE })
            DropdownMenuItem(text = { Text("Choose books") }, onClick = { menu = false; vm.startSelection(book) })
            if (onRemove != null) {
                DropdownMenuItem(
                    text = { Text("Remove from collection", color = palette.statusError) },
                    onClick = { menu = false; onRemove(book) },
                )
            }
        }
        pendingAction?.let { action ->
            AlertDialog(
                onDismissRequest = { pendingAction = null },
                title = { Text(action.title) },
                text = { Text(action.message(book.title)) },
                confirmButton = {
                    TextButton(onClick = {
                        when (action) {
                            BookCardDestructiveAction.REMOVE_DOWNLOAD -> vm.removeDownload(book)
                            BookCardDestructiveAction.HIDE -> vm.hide(book)
                        }
                        pendingAction = null
                    }) { Text(action.confirmLabel, color = palette.statusError) }
                },
                dismissButton = { TextButton(onClick = { pendingAction = null }) { Text("Cancel") } },
            )
        }
    }
}

internal fun isAudioPlayable(book: Book): Boolean =
    book.mediaType == AppMediaType.AUDIOBOOK || book.mediaType == AppMediaType.PODCAST || book.hasAudio

private enum class BookCardDestructiveAction(val title: String, val confirmLabel: String) {
    REMOVE_DOWNLOAD("Remove download?", "Remove"),
    HIDE("Hide from library?", "Hide"),
    ;

    fun message(bookTitle: String): String = when (this) {
        REMOVE_DOWNLOAD -> "This removes the downloaded files for \"$bookTitle\" from this device."
        HIDE -> "This hides \"$bookTitle\" from Enve's library."
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DenseBookRow(
    book: Book,
    vm: HearthLibraryViewModel,
    selectionMode: Boolean,
    selected: Boolean,
    onOpen: (Book) -> Unit,
    onPlay: (Book) -> Unit,
    onRemove: ((Book) -> Unit)?,
) {
    val palette = Hearth.palette
    var menu by remember { mutableStateOf(false) }
    var pendingAction by remember(book.uniqueKey) { mutableStateOf<BookCardDestructiveAction?>(null) }
    Row(
        Modifier.fillMaxWidth().combinedClickable(
            onClick = { if (selectionMode) vm.toggleSelected(book) else onOpen(book) },
            onLongClick = { if (!selectionMode) menu = true },
        ).padding(vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CoverTile(
            model = book.coverUrl,
            mediaType = book.mediaType,
            modifier = Modifier.width(44.dp),
            contentDescription = book.title,
            progress = com.enve.hearth.design.HearthFormat.progress(book),
            isFinished = book.isFinished,
        )
        Spacer(Modifier.width(Hearth.Spacing.M))
        Column(Modifier.weight(1f)) {
            Text(book.title, style = hearthDisplay(15.sp, FontWeight.SemiBold), color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            book.author?.let { Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
        if (book.isDownloaded) {
            Icon(
                Icons.Outlined.Download,
                contentDescription = "Downloaded",
                tint = palette.textTertiary,
                modifier = Modifier.padding(end = Hearth.Spacing.S).size(18.dp),
            )
        }
        if (selected) {
            Icon(Icons.Filled.CheckCircle, contentDescription = "Selected", tint = palette.ember, modifier = Modifier.size(22.dp))
        } else if (!selectionMode) {
            Box {
                Icon(
                    Icons.Outlined.MoreVert,
                    contentDescription = "Actions for ${book.title}",
                    tint = palette.textSecondary,
                    modifier = Modifier.clip(CircleShape).clickable { menu = true }.padding(Hearth.Spacing.S).size(20.dp),
                )
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    val listen = isAudioPlayable(book)
                    DropdownMenuItem(text = { Text(if (listen) "Play" else "Read") }, onClick = { menu = false; onPlay(book) })
                    if (listen) {
                        DropdownMenuItem(text = { Text("Play next") }, onClick = { menu = false; vm.addNext(book) })
                        DropdownMenuItem(text = { Text("Add to Up Next") }, onClick = { menu = false; vm.addLast(book) })
                    }
                    DropdownMenuItem(
                        text = { Text(if (book.isFinished) "Mark unfinished" else "Mark finished") },
                        onClick = { menu = false; vm.setFinished(book, !book.isFinished) },
                    )
                    if (book.source != BookSource.LOCAL) {
                        if (book.isDownloaded) {
                            DropdownMenuItem(text = { Text("Remove download") }, onClick = { menu = false; pendingAction = BookCardDestructiveAction.REMOVE_DOWNLOAD })
                        } else {
                            DropdownMenuItem(text = { Text("Download") }, onClick = { menu = false; vm.download(book) })
                        }
                    }
                    DropdownMenuItem(text = { Text("Hide from library") }, onClick = { menu = false; pendingAction = BookCardDestructiveAction.HIDE })
                    DropdownMenuItem(text = { Text("Choose books") }, onClick = { menu = false; vm.startSelection(book) })
                    if (onRemove != null) {
                        DropdownMenuItem(
                            text = { Text("Remove from collection", color = palette.statusError) },
                            onClick = { menu = false; onRemove(book) },
                        )
                    }
                }
            }
        }
    }
    pendingAction?.let { action ->
        AlertDialog(
            onDismissRequest = { pendingAction = null },
            title = { Text(action.title) },
            text = { Text(action.message(book.title)) },
            confirmButton = {
                TextButton(onClick = {
                    when (action) {
                        BookCardDestructiveAction.REMOVE_DOWNLOAD -> vm.removeDownload(book)
                        BookCardDestructiveAction.HIDE -> vm.hide(book)
                    }
                    pendingAction = null
                }) { Text(action.confirmLabel, color = palette.statusError) }
            },
            dismissButton = { TextButton(onClick = { pendingAction = null }) { Text("Cancel") } },
        )
    }
}
