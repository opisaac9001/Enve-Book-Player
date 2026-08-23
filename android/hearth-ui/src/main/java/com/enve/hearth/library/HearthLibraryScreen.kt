package com.enve.hearth.library

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items as listItems
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ViewList
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.BrowseGroup
import com.enve.core.data.model.Library
import com.enve.engine.library.BookOrbitCollectionEdit
import com.enve.engine.library.LibraryConnectionOption
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.Ribbon
import com.enve.hearth.design.ShelfHeader
import com.enve.hearth.design.hearthDisplay
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HearthLibraryScreen(
    onSelectBook: (Book) -> Unit,
    onPlayBook: (Book) -> Unit = {},
    onPlaybackStarted: () -> Unit = {},
    onAddSource: () -> Unit = {},
) {
    val vm: HearthLibraryViewModel = hiltViewModel()
    val facet by vm.facet.collectAsStateWithLifecycle()
    val query by vm.query.collectAsStateWithLifecycle()
    val status by vm.status.collectAsStateWithLifecycle()
    val sortStack by vm.sortStack.collectAsStateWithLifecycle()
    val usesDefaultSorting by vm.usesDefaultSorting.collectAsStateWithLifecycle()
    val advancedFilters by vm.advancedFilters.collectAsStateWithLifecycle()
    val mediaFilter by vm.media.collectAsStateWithLifecycle()
    val sourceFilter by vm.sourceFilter.collectAsStateWithLifecycle()
    val libraryFilter by vm.libraryFilter.collectAsStateWithLifecycle()
    var showFilterSort by remember { mutableStateOf(false) }
    val books by vm.books.collectAsStateWithLifecycle()
    val series by vm.series.collectAsStateWithLifecycle()
    val authors by vm.authors.collectAsStateWithLifecycle()
    val narrators by vm.narrators.collectAsStateWithLifecycle()
    val shelves by vm.shelves.collectAsStateWithLifecycle()
    val shelvesLoading by vm.shelvesLoading.collectAsStateWithLifecycle()
    val bookOrbitAdminConnections by vm.bookOrbitAdminConnections.collectAsStateWithLifecycle()
    val hasGrimmoryConnection by vm.hasGrimmoryConnection.collectAsStateWithLifecycle()
    val drill by vm.drill.collectAsStateWithLifecycle()
    val total by vm.totalCount.collectAsStateWithLifecycle()
    val refreshing by vm.isRefreshing.collectAsStateWithLifecycle()
    val columns by vm.columns.collectAsStateWithLifecycle()
    val selectionMode by vm.selectionMode.collectAsStateWithLifecycle()
    val selection by vm.selection.collectAsStateWithLifecycle()
    val batchCollectionPicker by vm.batchCollectionPicker.collectAsStateWithLifecycle()
    var searchExpanded by remember { mutableStateOf(false) }
    var collectionEditor by remember { mutableStateOf<BrowseGroup?>(null) }
    var creatingCollection by remember { mutableStateOf(false) }
    var pendingBookRemoval by remember { mutableStateOf<Book?>(null) }
    var pendingBulkAction by remember { mutableStateOf<BulkAction?>(null) }
    var batchCollectionCreateConnection by remember { mutableStateOf<LibraryConnectionOption?>(null) }
    val palette = Hearth.palette
    BackHandler(enabled = drill != null || selectionMode || searchExpanded) {
        when {
            searchExpanded -> { searchExpanded = false; vm.setQuery("") }
            selectionMode -> vm.endSelection()
            else -> vm.clearDrill()
        }
    }

    val compact = Hearth.typeCompact
    val headerGap = if (compact) Hearth.Spacing.S else Hearth.Spacing.M
    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = vm::refresh,
        modifier = Modifier.fillMaxSize(),
    ) {
        Box(Modifier.fillMaxSize().background(palette.bg)) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL, vertical = headerGap),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Overline("$total in your library")
                Text("Library", style = HearthText.ScreenTitle, color = palette.text)
            }
            if (refreshing) {
                CircularProgressIndicator(color = palette.ember, strokeWidth = 2.dp, modifier = Modifier.padding(Hearth.Spacing.S).size(20.dp))
            } else {
                HeaderGlyph(Icons.Outlined.Refresh, "Refresh") { vm.refresh() }
            }
            HeaderGlyph(
                if (columns == 1) Icons.Outlined.GridView else Icons.AutoMirrored.Outlined.ViewList,
                when (columns) {
                    1 -> "Show grid"
                    4 -> "Show list"
                    else -> "Increase grid columns"
                },
            ) { vm.cycleColumns() }
            HeaderGlyph(Icons.Outlined.Add, "Add a source", onClick = onAddSource)
        }
        val sources by vm.sources.collectAsStateWithLifecycle()
        val libraries by vm.libraries.collectAsStateWithLifecycle()
        val libraryConnectionLabels by vm.libraryConnectionLabels.collectAsStateWithLifecycle()
        SourceLibraryControls(
            sources = sources,
            libraries = libraries,
            libraryConnectionLabels = libraryConnectionLabels,
            sourceFilter = sourceFilter,
            libraryFilter = libraryFilter,
            onSource = vm::setSourceFilter,
            onLibrary = vm::setLibraryFilter,
            modifier = Modifier.padding(horizontal = Hearth.Spacing.XL),
        )
        Spacer(Modifier.size(headerGap))
        QuickShelves(status) {
            vm.setFacet(LibraryFacet.BOOKS)
            vm.setStatus(it)
        }
        Spacer(Modifier.size(headerGap))
        FacetRow(facet, vm::setFacet)
        Spacer(Modifier.size(headerGap))

        val drillNow = drill
        when {
            drillNow != null -> Column(Modifier.fillMaxSize()) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.S),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("‹ Back", style = HearthText.Label, color = palette.ember, modifier = Modifier.clickable { vm.clearDrill() })
                    Spacer(Modifier.width(Hearth.Spacing.M))
                    Text(drillNow.title, style = hearthDisplay(20.sp, FontWeight.SemiBold), color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Spacer(Modifier.weight(1f))
                    if (drillNow.kind != DrillKind.SHELF && drillNow.books.any(::isAudioPlayable)) {
                        TextButton(onClick = {
                            if (vm.playAllDrill()) onPlaybackStarted()
                        }) { Text("Play All", color = palette.ember) }
                    }
                    if (drillNow.shelf?.isEditable == true) {
                        Text("Edit", style = HearthText.Label, color = palette.ember, modifier = Modifier.clickable { collectionEditor = drillNow.shelf })
                    }
                }
                BookGrid(
                    drillNow.books,
                    columns,
                    vm,
                    selectionMode,
                    selection,
                    onSelectBook,
                    onPlayBook,
                    onRemove = if (drillNow.shelf?.isEditable == true) ({ pendingBookRemoval = it }) else null,
                )
                if (drillNow.hasMore) {
                    TextButton(
                        onClick = vm::loadMoreShelf,
                        enabled = !drillNow.loadingMore,
                        modifier = Modifier.align(Alignment.CenterHorizontally),
                    ) { Text(if (drillNow.loadingMore) "Loading…" else "Load more") }
                }
            }

            facet == LibraryFacet.BOOKS -> Column(Modifier.fillMaxSize()) {
                val activeFilterCount = remember(
                    status,
                    mediaFilter,
                    sourceFilter,
                    libraryFilter,
                    advancedFilters,
                ) {
                    (if (status != StatusFilter.ALL) 1 else 0) +
                        (if (mediaFilter != MediaFilter.ALL) 1 else 0) +
                        (if (sourceFilter != null) 1 else 0) +
                        (if (libraryFilter != null) 1 else 0) +
                        advancedFilters.genres.size +
                        advancedFilters.languages.size +
                        (if (advancedFilters.minimumRating != null) 1 else 0) +
                        (if (advancedFilters.series != SeriesFilter.ALL) 1 else 0)
                }
                ChipBar(
                    sortStack = sortStack,
                    resultCount = books.size,
                    activeFilterCount = activeFilterCount,
                    usesDefaultSorting = usesDefaultSorting,
                    onOpenSort = { showFilterSort = true },
                )
                Spacer(Modifier.size(Hearth.Spacing.M))
                BookGrid(books, columns, vm, selectionMode, selection, onSelectBook, onPlayBook)
            }

            facet == LibraryFacet.SERIES -> BrowseLayout(series, columns) { vm.openSeries(it.name) }
            facet == LibraryFacet.AUTHORS -> BrowseLayout(authors, columns) { vm.openAuthor(it.name) }
            facet == LibraryFacet.NARRATORS -> BrowseLayout(narrators, columns) { vm.openNarrator(it.name) }
            facet == LibraryFacet.SHELVES -> when {
                shelvesLoading -> BrowseLoadingState()
                shelves.isEmpty() && bookOrbitAdminConnections.isEmpty() -> EmptyShelvesState(hasGrimmoryConnection)
                else -> ShelvesList(
                    groups = shelves,
                    canCreate = bookOrbitAdminConnections.isNotEmpty(),
                    onCreate = { creatingCollection = true },
                    onOpen = vm::openShelf,
                    onEdit = { collectionEditor = it },
                    onMove = vm::moveBookOrbitCollection,
                )
            }
        }
    }

    if (showFilterSort) {
        FilterSortSheet(vm = vm, onDismiss = { showFilterSort = false })
    }

    if (selectionMode) {
        BulkActionBar(
            count = selection.size,
            onSelectAll = vm::selectAllVisible,
            onPlay = {
                if (vm.playSelected()) onPlaybackStarted()
            },
            onDownload = vm::bulkDownload,
            onCollections = vm::openBatchCollectionPicker,
            onQueue = vm::bulkAddToUpNext,
            onFinished = { pendingBulkAction = BulkAction.MARK_READ },
            onHide = { pendingBulkAction = BulkAction.HIDE },
            onCancel = vm::endSelection,
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = LocalMantelInset.current + Hearth.Spacing.M),
        )
    }

    val notice by vm.notice.collectAsStateWithLifecycle()
    notice?.let { msg ->
        LaunchedEffect(msg) {
            kotlinx.coroutines.delay(4000)
            vm.dismissNotice()
        }
        Box(
            Modifier.align(Alignment.BottomCenter).padding(bottom = LocalMantelInset.current)
                .padding(horizontal = Hearth.Spacing.XL)
                .clip(RoundedCornerShape(999.dp))
                .background(Hearth.palette.bgElevated)
                .border(1.dp, Hearth.palette.hairline, RoundedCornerShape(999.dp))
                .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.S),
        ) {
            Text(msg, style = HearthText.Caption, color = Hearth.palette.text)
        }
    }

    if (!selectionMode) {
        FloatingSearch(
            query = query,
            onQuery = vm::setQuery,
            expanded = searchExpanded,
            onExpandedChange = { open ->
                searchExpanded = open
                if (!open) vm.setQuery("")
            },
            modifier = Modifier.align(Alignment.BottomCenter),
        )
    }

    if (creatingCollection) {
        BookOrbitCollectionDialog(
            collection = null,
            connections = bookOrbitAdminConnections,
            onDismiss = { creatingCollection = false },
            onSave = { connectionId, edit ->
                vm.createBookOrbitCollection(connectionId, edit)
                creatingCollection = false
            },
        )
    }
    if (batchCollectionPicker.isVisible) {
        BatchCollectionPickerDialog(
            state = batchCollectionPicker,
            onDismiss = vm::closeBatchCollectionPicker,
            onSelect = vm::addSelectedToBookOrbitCollection,
            onCreate = {
                batchCollectionCreateConnection = batchCollectionPicker.connection
                vm.closeBatchCollectionPicker()
            },
        )
    }
    batchCollectionCreateConnection?.let { connection ->
        BookOrbitCollectionDialog(
            collection = null,
            connections = listOf(connection),
            onDismiss = { batchCollectionCreateConnection = null },
            onSave = { connectionId, edit ->
                vm.createBookOrbitCollectionFromSelection(connectionId, edit)
                batchCollectionCreateConnection = null
            },
        )
    }
    collectionEditor?.let { collection ->
        BookOrbitCollectionDialog(
            collection = collection,
            connections = bookOrbitAdminConnections,
            onDismiss = { collectionEditor = null },
            onSave = { _, edit ->
                vm.updateBookOrbitCollection(collection, edit)
                collectionEditor = null
            },
            onDelete = {
                vm.deleteBookOrbitCollection(collection)
                collectionEditor = null
            },
        )
    }
    pendingBookRemoval?.let { book ->
        AlertDialog(
            onDismissRequest = { pendingBookRemoval = null },
            title = { Text("Remove from collection?") },
            text = { Text("Remove \"${book.title}\" from \"${drill?.title.orEmpty()}\" on BookOrbit?") },
            confirmButton = {
                TextButton(onClick = { vm.removeBookFromShelf(book); pendingBookRemoval = null }) {
                    Text("Remove", color = palette.statusError)
                }
            },
            dismissButton = { TextButton(onClick = { pendingBookRemoval = null }) { Text("Cancel") } },
        )
    }
    pendingBulkAction?.let { action ->
        AlertDialog(
            onDismissRequest = { pendingBulkAction = null },
            title = { Text(action.title) },
            text = { Text(action.message(selection.size)) },
            confirmButton = {
                TextButton(onClick = {
                    when (action) {
                        BulkAction.MARK_READ -> vm.bulkFinished(true)
                        BulkAction.HIDE -> vm.bulkHide()
                    }
                    pendingBulkAction = null
                }) {
                    Text(action.confirmLabel, color = if (action == BulkAction.HIDE) palette.statusError else palette.ember)
                }
            },
            dismissButton = { TextButton(onClick = { pendingBulkAction = null }) { Text("Cancel") } },
        )
        }
    }
}
}

private enum class BulkAction(val title: String, val confirmLabel: String) {
    MARK_READ("Mark selected books as read?", "Mark read"),
    HIDE("Hide selected books?", "Hide"),
    ;

    fun message(count: Int): String = when (this) {
        MARK_READ -> "This will update the reading status for $count selected ${if (count == 1) "book" else "books"}."
        HIDE -> "This will hide $count selected ${if (count == 1) "book" else "books"} from the library."
    }
}

@Composable
private fun HeaderGlyph(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Icon(
        icon, contentDescription = label, tint = Hearth.palette.textSecondary,
        modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onClick).padding(Hearth.Spacing.S).size(22.dp),
    )
}

@Composable
private fun BulkActionBar(
    count: Int,
    onSelectAll: () -> Unit,
    onPlay: () -> Unit,
    onDownload: () -> Unit,
    onCollections: () -> Unit,
    onQueue: () -> Unit,
    onFinished: () -> Unit,
    onHide: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Bar)
    var menuExpanded by remember { mutableStateOf(false) }
    Row(
        modifier.padding(horizontal = Hearth.Spacing.XL).fillMaxWidth().clip(shape)
            .background(palette.bgElevated).border(1.dp, palette.hairline, shape)
            .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Text("$count selected", style = HearthText.Label, color = palette.ember, modifier = Modifier.weight(1f))
        HeaderGlyph(Icons.Filled.PlayArrow, "Play selected", onPlay)
        HeaderGlyph(Icons.Outlined.Download, "Download selected", onDownload)
        HeaderGlyph(Icons.Outlined.Folder, "Add selected to collection", onCollections)
        Box {
            HeaderGlyph(Icons.Outlined.MoreVert, "More selection actions") { menuExpanded = true }
            DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                DropdownMenuItem(
                    text = { Text("Select all") },
                    onClick = { menuExpanded = false; onSelectAll() },
                )
                DropdownMenuItem(
                    text = { Text("Add to Up Next") },
                    onClick = { menuExpanded = false; onQueue() },
                )
                DropdownMenuItem(
                    text = { Text("Mark as read") },
                    onClick = { menuExpanded = false; onFinished() },
                )
                DropdownMenuItem(
                    text = { Text("Hide from library") },
                    onClick = { menuExpanded = false; onHide() },
                )
            }
        }
        HeaderGlyph(Icons.Outlined.Close, "Cancel selection", onCancel)
    }
}

@Composable
private fun BatchCollectionPickerDialog(
    state: BatchCollectionPickerState,
    onDismiss: () -> Unit,
    onSelect: (BrowseGroup) -> Unit,
    onCreate: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add to BookOrbit collection") },
        text = {
            when {
                state.isLoading -> Box(Modifier.fillMaxWidth().padding(Hearth.Spacing.XL), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = Hearth.palette.ember, strokeWidth = 2.dp, modifier = Modifier.size(28.dp))
                }
                state.connection == null -> Text("No editable BookOrbit collections are available.")
                else -> Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    TextButton(onClick = onCreate) { Text("+ New collection", color = Hearth.palette.ember) }
                    if (state.collections.isEmpty()) {
                        Text("Create a collection for the selected books.", style = HearthText.Body, color = Hearth.palette.textSecondary)
                    } else {
                        Column(Modifier.fillMaxWidth().heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
                            state.collections.forEach { collection ->
                                Row(
                                    Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Inner))
                                        .clickable { onSelect(collection) }
                                        .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.M),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Column(Modifier.weight(1f)) {
                                        Text(collection.name, style = HearthText.Body, color = Hearth.palette.text)
                                        Text(
                                            "${collection.count} ${if (collection.count == 1) "book" else "books"}",
                                            style = HearthText.Caption,
                                            color = Hearth.palette.textSecondary,
                                        )
                                    }
                                    Text("+", style = HearthText.Label, color = Hearth.palette.ember)
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

@Composable
private fun SourceLibraryControls(
    sources: List<BookSource>,
    libraries: List<Library>,
    libraryConnectionLabels: Map<String, String>,
    sourceFilter: BookSource?,
    libraryFilter: String?,
    onSource: (BookSource?) -> Unit,
    onLibrary: (String?) -> Unit,
    modifier: Modifier = Modifier,
) {
    val selectedLibrary = libraries.firstOrNull { it.id == libraryFilter }
    val duplicateLibraryNames = libraries.groupingBy { it.name }.eachCount().filterValues { it > 1 }.keys
    fun librarySupportingText(lib: Library): String? {
        val connection = lib.connectionId?.let(libraryConnectionLabels::get)
        return when {
            lib.name in duplicateLibraryNames && connection != null -> connection
            lib.name in duplicateLibraryNames -> lib.source.displayName
            else -> null
        }
    }
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        SelectorPill(
            label = "Source",
            value = sourceFilter?.displayName ?: "All sources",
            options = listOf(
                SelectorOption(
                    title = "All sources",
                    selected = sourceFilter == null,
                    onSelect = { onSource(null) },
                ),
            ) + sources.map { source ->
                SelectorOption(
                    title = source.displayName,
                    selected = sourceFilter == source,
                    onSelect = { onSource(source) },
                )
            },
            active = sourceFilter != null,
            modifier = Modifier.weight(1f),
        )
        SelectorPill(
            label = "Library",
            value = when {
                selectedLibrary != null -> selectedLibrary.name
                sourceFilter != null -> "All in ${sourceFilter.displayName}"
                else -> "All libraries"
            },
            options = listOf(
                SelectorOption(
                    title = if (sourceFilter != null) "All in ${sourceFilter.displayName}" else "All libraries",
                    selected = libraryFilter == null,
                    onSelect = { onLibrary(null) },
                ),
            ) + libraries.map { lib ->
                SelectorOption(
                    title = lib.name,
                    supportingText = librarySupportingText(lib),
                    selected = libraryFilter == lib.id,
                    onSelect = { onLibrary(lib.id) },
                )
            },
            active = libraryFilter != null || sourceFilter != null,
            modifier = Modifier.weight(1f),
        )
    }
}

private data class SelectorOption(
    val title: String,
    val supportingText: String? = null,
    val selected: Boolean = false,
    val onSelect: () -> Unit,
)

@Composable
private fun SelectorPill(
    label: String,
    value: String,
    options: List<SelectorOption>,
    active: Boolean,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(22.dp)
    var open by remember { mutableStateOf(false) }
    Box(modifier) {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(palette.bgElevated)
                .border(1.dp, if (active) palette.ember.copy(alpha = 0.45f) else palette.hairline, shape)
                .clickable { open = true }
                .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            Box(
                Modifier
                    .size(10.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(if (active) palette.ember else palette.textTertiary.copy(alpha = 0.45f)),
            )
            Column(
                Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(label, style = HearthText.Overline, color = palette.textTertiary, maxLines = 1)
                Text(
                    value,
                    style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
            shape = RoundedCornerShape(28.dp),
            containerColor = palette.bgElevated,
            tonalElevation = 0.dp,
            shadowElevation = 0.dp,
            border = BorderStroke(1.dp, palette.hairline),
        ) {
            Column(Modifier.widthIn(min = 220.dp, max = 280.dp).padding(vertical = Hearth.Spacing.S)) {
                options.forEach { option ->
                    SelectorMenuRow(
                        option = option,
                        onClick = {
                            option.onSelect()
                            open = false
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun SelectorMenuRow(option: SelectorOption, onClick: () -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.M),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Icon(
            imageVector = if (option.selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (option.selected) palette.text else palette.textTertiary,
            modifier = Modifier.size(20.dp),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                option.title,
                style = HearthText.Label.copy(fontWeight = if (option.selected) FontWeight.SemiBold else FontWeight.Normal),
                color = palette.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            option.supportingText?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = HearthText.Overline, color = palette.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun QuickShelves(status: StatusFilter, onStatus: (StatusFilter) -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        ShelfHeader("Shelves", modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL))
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = Hearth.Spacing.XL),
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            ShelfShortcut("Everything", "All sources", selected = status == StatusFilter.ALL) { onStatus(StatusFilter.ALL) }
            ShelfShortcut("Currently reading", "All media", selected = status == StatusFilter.CURRENTLY_READING) { onStatus(StatusFilter.CURRENTLY_READING) }
            ShelfShortcut("Unread", "Not marked read", selected = status == StatusFilter.UNREAD) { onStatus(StatusFilter.UNREAD) }
            ShelfShortcut("Read", "Completed", selected = status == StatusFilter.FINISHED) { onStatus(StatusFilter.FINISHED) }
            ShelfShortcut("Downloaded", "On this device", selected = status == StatusFilter.DOWNLOADED) { onStatus(StatusFilter.DOWNLOADED) }
        }
    }
}

@Composable
private fun ShelfShortcut(title: String, line: String, selected: Boolean, onClick: () -> Unit) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)

    Column(
        Modifier
            .widthIn(min = 132.dp)
            .clip(shape)
            .background(if (selected) palette.ember.copy(alpha = 0.18f) else palette.bgElevated)
            .border(1.dp, if (selected) palette.ember.copy(alpha = 0.55f) else palette.hairline, shape)
            .clickable(onClick = onClick)
            .padding(Hearth.Spacing.M),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
    ) {
        Text(title, style = HearthText.Caption.copy(fontWeight = FontWeight.SemiBold), color = if (selected) palette.ember else palette.text, maxLines = 1)
        Text(line, style = HearthText.Overline, color = palette.textTertiary, maxLines = 1)
    }
}

@Composable
private fun FloatingSearch(
    query: String,
    onQuery: (String) -> Unit,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val focusRequester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current

    Row(
        modifier
            .fillMaxWidth()
            .imePadding()
            .padding(bottom = if (expanded) Hearth.Spacing.M else LocalMantelInset.current)
            .padding(horizontal = 20.dp),
        horizontalArrangement = Arrangement.End,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (expanded) {
            LaunchedEffect(Unit) { focusRequester.requestFocus() }
            val shape = RoundedCornerShape(50)
            Row(
                Modifier
                    .weight(1f)
                    .then(if (eink.suppressShadows) Modifier else Modifier.shadow(14.dp, shape, clip = false))
                    .clip(shape)
                    .background(palette.bgElevated)
                    .border(1.dp, palette.hairline, shape)
                    .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Search, contentDescription = null, tint = palette.textTertiary, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(Hearth.Spacing.S))
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) {
                        Text("Find a story…", style = hearthDisplay(18.sp, FontWeight.Normal).copy(fontStyle = FontStyle.Italic), color = palette.textTertiary)
                    }
                    BasicTextField(
                        value = query,
                        onValueChange = onQuery,
                        singleLine = true,
                        textStyle = hearthDisplay(18.sp, FontWeight.Normal).copy(color = palette.text),
                        cursorBrush = SolidColor(palette.ember),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(onSearch = { keyboard?.hide() }),
                        modifier = Modifier.fillMaxWidth().focusRequester(focusRequester),
                    )
                }
                Icon(
                    Icons.Outlined.Close,
                    contentDescription = "Close search",
                    tint = palette.textTertiary,
                    modifier = Modifier
                        .clip(CircleShape)
                        .clickable { keyboard?.hide(); onExpandedChange(false) }
                        .padding(Hearth.Spacing.XS)
                        .size(18.dp),
                )
            }
        } else {
            val shape = CircleShape
            Box(
                Modifier
                    .size(54.dp)
                    .then(if (eink.suppressShadows) Modifier else Modifier.shadow(12.dp, shape, clip = false))
                    .clip(shape)
                    .background(palette.bgElevated)
                    .border(1.dp, palette.hairline, shape)
                    .clickable { onExpandedChange(true) },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.Search, contentDescription = "Search the library", tint = palette.ember, modifier = Modifier.size(22.dp))
            }
        }
    }
}

@Composable
private fun FacetRow(facet: LibraryFacet, onSelect: (LibraryFacet) -> Unit) {

    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = Hearth.Spacing.XL),
        horizontalArrangement = Arrangement.spacedBy(if (Hearth.typeCompact) Hearth.Spacing.L else Hearth.Spacing.XL),
    ) {
        LibraryFacet.entries.forEach { f ->
            val selected = f == facet
            Text(
                f.name.lowercase().replaceFirstChar { it.uppercase() },
                style = HearthText.Overline,
                color = if (selected) Hearth.palette.ember else Hearth.palette.textTertiary,
                maxLines = 1,
                softWrap = false,
                modifier = Modifier.clickable { onSelect(f) }.padding(vertical = Hearth.Spacing.XS),
            )
        }
    }
}

@Composable
private fun ChipBar(
    sortStack: List<SortDescriptor>,
    resultCount: Int,
    activeFilterCount: Int,
    usesDefaultSorting: Boolean,
    onOpenSort: () -> Unit,
) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val narrowed = activeFilterCount > 0
        val title = when {
            narrowed -> "Filters $activeFilterCount"
            usesDefaultSorting -> "Filter & Sort"
            else -> "Sort: ${sortStack.firstOrNull()?.field?.label ?: "Recent"}"
        }
        Row(
            Modifier.clip(RoundedCornerShape(50))
                .background(if (narrowed) palette.ember.copy(alpha = 0.16f) else palette.bgElevated)
                .border(1.dp, if (narrowed) palette.ember.copy(alpha = 0.5f) else palette.hairline, RoundedCornerShape(50))
                .clickable(onClick = onOpenSort)
                .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.FilterList, contentDescription = null, tint = if (narrowed) palette.ember else palette.textSecondary, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(Hearth.Spacing.XS))
            Text(title, style = HearthText.Caption, color = if (narrowed) palette.ember else palette.textSecondary, maxLines = 1)
        }
        Spacer(Modifier.weight(1f))
        Text(
            if (resultCount == 1) "1 book" else "$resultCount books",
            style = HearthText.Caption,
            color = palette.textTertiary,
            maxLines = 1,
        )
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun FilterSortSheet(vm: HearthLibraryViewModel, onDismiss: () -> Unit) {
    val palette = Hearth.palette
    val sortStack by vm.sortStack.collectAsStateWithLifecycle()
    val status by vm.status.collectAsStateWithLifecycle()
    val media by vm.media.collectAsStateWithLifecycle()
    val advanced by vm.advancedFilters.collectAsStateWithLifecycle()
    val advancedOptions by vm.advancedFilterOptions.collectAsStateWithLifecycle()
    val sheetShape = if (Hearth.eink.sharpCorners) {
        androidx.compose.ui.graphics.RectangleShape
    } else {
        androidx.compose.material3.BottomSheetDefaults.ExpandedShape
    }
    androidx.compose.material3.ModalBottomSheet(onDismissRequest = onDismiss, shape = sheetShape, containerColor = palette.bgElevated) {
        Column(
            Modifier.fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Hearth.Spacing.XL)
                .padding(bottom = Hearth.Spacing.XXL),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Overline("Library")
                    Text("Filter & Sort", style = hearthDisplay(22.sp, FontWeight.SemiBold), color = palette.text)
                }
                Text(
                    "Done", style = HearthText.Label, color = palette.ember,
                    modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onDismiss)
                        .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
                )
            }

            Overline("Sort priority")
            sortStack.forEachIndexed { index, descriptor ->
                SortPriorityRow(
                    index = index,
                    descriptor = descriptor,
                    canMoveUp = index > 0,
                    canMoveDown = index < sortStack.lastIndex,
                    canRemove = sortStack.size > 1,
                    onDirection = { vm.setSortDirection(descriptor.field, it) },
                    onUp = { vm.moveSortUp(descriptor.field) },
                    onDown = { vm.moveSortDown(descriptor.field) },
                    onRemove = { vm.removeSort(descriptor.field) },
                )
            }

            val unused = LibrarySort.entries.filter { field -> sortStack.none { it.field == field } }
            if (unused.isNotEmpty()) {
                Overline("Add sort")
                androidx.compose.foundation.layout.FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                    verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                ) {
                    unused.forEach { field ->
                        HearthChip("+ ${field.label}", selected = false, onClick = { vm.addSort(field) })
                    }
                }
            }

            Overline("Primary direction")
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                SortDirection.entries.forEach { dir ->
                    HearthChip(
                        "${dir.arrow} ${dir.label}",
                        selected = sortStack.firstOrNull()?.direction == dir,
                        onClick = { vm.setPrimaryDirection(dir) },
                    )
                }
            }

            Overline("Status")
            androidx.compose.foundation.layout.FlowRow(
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                StatusFilter.entries.forEach { s ->
                    HearthChip(s.label, selected = s == status, onClick = { vm.setStatus(s) })
                }
            }

            Overline("Media")
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                MediaFilter.entries.forEach { m ->
                    HearthChip(m.label, selected = m == media, onClick = { vm.setMedia(m) })
                }
            }

            Overline("Rating")
            androidx.compose.foundation.layout.FlowRow(
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                listOf<Float?>(null, 3f, 4f, 4.5f).forEach { rating ->
                    HearthChip(
                        label = rating?.let { "${"%.1f".format(it)}+ stars" } ?: "Any rating",
                        selected = advanced.minimumRating == rating,
                        onClick = { vm.setMinimumRating(rating) },
                    )
                }
            }

            Overline("Series")
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                SeriesFilter.entries.forEach { series ->
                    HearthChip(
                        series.label,
                        selected = advanced.series == series,
                        onClick = { vm.setSeriesFilter(series) },
                    )
                }
            }

            val genres = (advancedOptions.genres + advanced.genres)
                .distinct()
                .sortedWith(String.CASE_INSENSITIVE_ORDER)
            if (genres.isNotEmpty()) {
                Overline("Genres")
                androidx.compose.foundation.layout.FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                    verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                ) {
                    genres.forEach { genre ->
                        HearthChip(
                            genre,
                            selected = genre in advanced.genres,
                            onClick = { vm.toggleGenre(genre) },
                        )
                    }
                }
            }

            val languages = (advancedOptions.languages + advanced.languages)
                .distinct()
                .sortedWith(String.CASE_INSENSITIVE_ORDER)
            if (languages.isNotEmpty()) {
                Overline("Languages")
                androidx.compose.foundation.layout.FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                    verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                ) {
                    languages.forEach { language ->
                        HearthChip(
                            language,
                            selected = language in advanced.languages,
                            onClick = { vm.toggleLanguage(language) },
                        )
                    }
                }
            }

            Text(
                "Reset filters and sorting",
                style = HearthText.Label, color = palette.ember,
                modifier = Modifier.clip(RoundedCornerShape(50))
                    .clickable { vm.resetFiltersAndSorting() }
                    .padding(vertical = Hearth.Spacing.M),
            )
        }
    }
}

@Composable
private fun SortPriorityRow(
    index: Int,
    descriptor: SortDescriptor,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    canRemove: Boolean,
    onDirection: (SortDirection) -> Unit,
    onUp: () -> Unit,
    onDown: () -> Unit,
    onRemove: () -> Unit,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(palette.bg).border(1.dp, palette.hairline, shape)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Box(
            Modifier.size(24.dp).clip(RoundedCornerShape(50)).background(palette.ember.copy(alpha = 0.16f)),
            contentAlignment = Alignment.Center,
        ) {
            Text("${index + 1}", style = HearthText.Overline, color = palette.ember)
        }
        Text(descriptor.field.label, style = HearthText.Body, color = palette.text, modifier = Modifier.weight(1f))
        val flipped = if (descriptor.direction == SortDirection.ASCENDING) SortDirection.DESCENDING else SortDirection.ASCENDING
        RowGlyph(descriptor.direction.arrow, enabled = true) { onDirection(flipped) }
        RowGlyph("▲", enabled = canMoveUp, onClick = onUp)
        RowGlyph("▼", enabled = canMoveDown, onClick = onDown)
        RowGlyph("✕", enabled = canRemove, onClick = onRemove)
    }
}

@Composable
private fun RowGlyph(glyph: String, enabled: Boolean, onClick: () -> Unit) {
    val palette = Hearth.palette
    Text(
        glyph,
        style = HearthText.Label,
        color = if (enabled) palette.textSecondary else palette.textTertiary.copy(alpha = 0.4f),
        modifier = Modifier.clip(RoundedCornerShape(50))
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.XS),
    )
}

@Composable
private fun BookGrid(
    books: List<Book>,
    columns: Int,
    vm: HearthLibraryViewModel,
    selectionMode: Boolean,
    selection: Set<String>,
    onOpen: (Book) -> Unit,
    onPlay: (Book) -> Unit,
    onRemove: ((Book) -> Unit)? = null,
) {
    val eink = Hearth.eink
    val listLayout = eink.denseListLibrary || columns == 1
    if (books.isEmpty()) {
        EmptyLibraryState()
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
private fun BrowseLayout(groups: List<BrowseGroup>, columns: Int, onOpen: (BrowseGroup) -> Unit) {
    if (columns == 1 || Hearth.eink.denseListLibrary) {
        BrowseList(groups, onOpen)
    } else {
        BrowseGrid(groups, columns, onOpen)
    }
}

@Composable
private fun BrowseGrid(groups: List<BrowseGroup>, columns: Int, onOpen: (BrowseGroup) -> Unit) {
    val palette = Hearth.palette
    LazyVerticalGrid(
        columns = GridCells.Fixed(columns.coerceIn(2, 4)),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = Hearth.Spacing.XL,
            end = Hearth.Spacing.XL,
            bottom = LocalMantelInset.current + Hearth.Spacing.L,
        ),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
        modifier = Modifier.fillMaxSize(),
    ) {
        items(groups, key = { it.key }) { group ->
            Column(Modifier.fillMaxWidth().clickable { onOpen(group) }) {
                CoverTile(model = group.coverUrl, modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.size(Hearth.Spacing.S))
                Text(
                    group.name,
                    style = hearthDisplay(14.sp, FontWeight.SemiBold),
                    color = palette.text,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    "${group.count} ${if (group.count == 1) "book" else "books"}",
                    style = HearthText.Caption,
                    color = palette.textTertiary,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun EmptyLibraryState() {
    val palette = Hearth.palette
    Column(
        Modifier.fillMaxSize().padding(horizontal = Hearth.Spacing.XL),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("Nothing matches this filter.", style = hearthDisplay(22.sp, FontWeight.Bold), color = palette.text, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        Spacer(Modifier.size(Hearth.Spacing.S))
        Text(
            "Your shelves aren't empty. A filter is just hiding them.",
            style = HearthText.Body,
            color = palette.textSecondary,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
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
            if (book.isDownloaded) {
                DropdownMenuItem(text = { Text("Remove download") }, onClick = { menu = false; pendingAction = BookCardDestructiveAction.REMOVE_DOWNLOAD })
            } else {
                DropdownMenuItem(text = { Text("Download") }, onClick = { menu = false; vm.download(book) })
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

private fun isAudioPlayable(book: Book): Boolean =
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
                    if (book.isDownloaded) {
                        DropdownMenuItem(text = { Text("Remove download") }, onClick = { menu = false; pendingAction = BookCardDestructiveAction.REMOVE_DOWNLOAD })
                    } else {
                        DropdownMenuItem(text = { Text("Download") }, onClick = { menu = false; vm.download(book) })
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

@Composable
private fun BrowseList(groups: List<BrowseGroup>, onOpen: (BrowseGroup) -> Unit) {
    val palette = Hearth.palette
    LazyColumn(
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = Hearth.Spacing.XL, end = Hearth.Spacing.XL, bottom = LocalMantelInset.current + Hearth.Spacing.L,
        ),
        modifier = Modifier.fillMaxSize(),
    ) {
        listItems(groups, key = { it.key }) { g ->
            Row(
                Modifier.fillMaxWidth().clickable { onOpen(g) }.padding(vertical = Hearth.Spacing.M),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CoverTile(model = g.coverUrl, modifier = Modifier.width(44.dp))
                Spacer(Modifier.width(Hearth.Spacing.M))
                Column(Modifier.weight(1f)) {
                    Text(g.name, style = hearthDisplay(17.sp, FontWeight.SemiBold), color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    val count = "${g.count} ${if (g.count == 1) "book" else "books"}"
                    Text(listOfNotNull(g.secondary, count).joinToString(" · "), style = HearthText.Caption, color = palette.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun ShelvesList(
    groups: List<BrowseGroup>,
    canCreate: Boolean,
    onCreate: () -> Unit,
    onOpen: (BrowseGroup) -> Unit,
    onEdit: (BrowseGroup) -> Unit,
    onMove: (BrowseGroup, Int) -> Unit,
) {
    val palette = Hearth.palette
    LazyColumn(
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = Hearth.Spacing.XL,
            end = Hearth.Spacing.XL,
            bottom = LocalMantelInset.current + Hearth.Spacing.L,
        ),
        modifier = Modifier.fillMaxSize(),
    ) {
        if (canCreate) {
            item {
                TextButton(onClick = onCreate) { Text("+ New BookOrbit collection", color = palette.ember) }
            }
        }
        listItems(groups, key = { it.key }) { group ->
            Row(
                Modifier.fillMaxWidth().clickable { onOpen(group) }.padding(vertical = Hearth.Spacing.M),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CoverTile(model = group.coverUrl, modifier = Modifier.width(44.dp))
                Spacer(Modifier.width(Hearth.Spacing.M))
                Column(Modifier.weight(1f)) {
                    Text(group.name, style = hearthDisplay(17.sp, FontWeight.SemiBold), color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${group.count} ${if (group.count == 1) "book" else "books"}", style = HearthText.Caption, color = palette.textSecondary)
                }
                if (group.isEditable) {
                    TextButton(onClick = { onMove(group, -1) }) { Text("↑") }
                    TextButton(onClick = { onMove(group, 1) }) { Text("↓") }
                    TextButton(onClick = { onEdit(group) }) { Text("Edit") }
                }
            }
        }
    }
}

@Composable
private fun BookOrbitCollectionDialog(
    collection: BrowseGroup?,
    connections: List<LibraryConnectionOption>,
    onDismiss: () -> Unit,
    onSave: (String, BookOrbitCollectionEdit) -> Unit,
    onDelete: (() -> Unit)? = null,
) {
    var name by remember(collection?.key) { mutableStateOf(collection?.name.orEmpty()) }
    var description by remember(collection?.key) { mutableStateOf(collection?.description.orEmpty()) }
    var icon by remember(collection?.key) { mutableStateOf(collection?.icon ?: "FolderOpen") }
    var syncToKobo by remember(collection?.key) { mutableStateOf(collection?.syncToKobo ?: false) }
    var connectionId by remember(collection?.key, connections) {
        mutableStateOf(collection?.sourceConnectionId ?: connections.firstOrNull()?.id.orEmpty())
    }
    var connectionMenu by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }

    if (!confirmDelete) AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (collection == null) "New BookOrbit collection" else "Edit collection") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                if (collection == null && connections.size > 1) {
                    Box {
                        TextButton(onClick = { connectionMenu = true }) {
                            Text(connections.firstOrNull { it.id == connectionId }?.name ?: "Choose server")
                        }
                        DropdownMenu(expanded = connectionMenu, onDismissRequest = { connectionMenu = false }) {
                            connections.forEach { connection ->
                                DropdownMenuItem(
                                    text = { Text(connection.name) },
                                    onClick = { connectionId = connection.id; connectionMenu = false },
                                )
                            }
                        }
                    }
                }
                OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Name") }, singleLine = true)
                OutlinedTextField(value = description, onValueChange = { description = it }, label = { Text("Description") }, minLines = 2)
                OutlinedTextField(value = icon, onValueChange = { icon = it }, label = { Text("Icon") }, singleLine = true)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Sync to Kobo", modifier = Modifier.weight(1f))
                    Switch(checked = syncToKobo, onCheckedChange = { syncToKobo = it })
                }
                if (onDelete != null) {
                    TextButton(onClick = { confirmDelete = true }) {
                        Text("Delete collection", color = Hearth.palette.statusError)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = name.isNotBlank() && connectionId.isNotBlank(),
                onClick = {
                    onSave(
                        connectionId,
                        BookOrbitCollectionEdit(
                            name = name.trim(),
                            description = description.trim().ifBlank { null },
                            icon = icon.trim().ifBlank { "FolderOpen" },
                            syncToKobo = syncToKobo,
                        ),
                    )
                },
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete this collection?") },
            text = { Text("This permanently deletes \"$name\" from BookOrbit. Books in the collection remain in the library.") },
            confirmButton = {
                TextButton(onClick = { confirmDelete = false; onDelete?.invoke() }) {
                    Text("Delete", color = Hearth.palette.statusError)
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun BrowseLoadingState() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = Hearth.palette.ember, strokeWidth = 2.dp, modifier = Modifier.size(28.dp))
    }
}

@Composable
private fun EmptyShelvesState(hasGrimmoryConnection: Boolean) {
    val palette = Hearth.palette
    Box(Modifier.fillMaxSize().padding(horizontal = Hearth.Spacing.XL), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            Text(
                if (hasGrimmoryConnection) "No shelves found" else "No server collections found",
                style = hearthDisplay(20.sp, FontWeight.SemiBold),
                color = palette.text,
            )
            Text(
                if (hasGrimmoryConnection) "Create a shelf in Grimmory, then refresh." else "BookOrbit collections and Grimmory shelves will appear here.",
                style = HearthText.Caption,
                color = palette.textSecondary,
            )
        }
    }
}
