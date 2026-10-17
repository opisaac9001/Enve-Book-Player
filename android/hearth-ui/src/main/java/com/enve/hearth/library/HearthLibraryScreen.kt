package com.enve.hearth.library

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ViewList
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.hearth.shell.profileViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.BrowseGroup
import com.enve.core.data.model.Library
import com.enve.engine.library.LibraryConnectionOption
import com.enve.engine.library.SavedBookList
import com.enve.hearth.collections.CollectionsScreen
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.hearthDisplay
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HearthLibraryScreen(
    covered: Boolean,
    onSelectBook: (Book) -> Unit,
    onPlayBook: (Book) -> Unit = {},
    onPlaybackStarted: () -> Unit = {},
    onAddSource: () -> Unit = {},
    onOpenSettings: () -> Unit = {},
) {
    var showPersonalCollections by rememberSaveable { mutableStateOf(false) }
    if (showPersonalCollections) {
        CollectionsScreen(onBack = { showPersonalCollections = false }, onOpenBook = onSelectBook)
        return
    }
    val vm: HearthLibraryViewModel = profileViewModel()
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
    val savedBooks by vm.savedBooks.collectAsStateWithLifecycle()
    var savedList by remember { mutableStateOf<SavedBookList?>(null) }
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
    BackHandler(enabled = !covered && (drill != null || savedList != null || selectionMode || searchExpanded)) {
        when {
            searchExpanded -> { searchExpanded = false; vm.setQuery("") }
            selectionMode -> vm.endSelection()
            savedList != null -> savedList = null
            else -> vm.clearDrill()
        }
    }
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(covered) { if (covered) keyboard?.hide() }

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
            HeaderGlyph(Icons.Outlined.Refresh, "Refresh", enabled = !refreshing) { vm.refresh() }
            HeaderGlyph(
                if (columns == 1) Icons.Outlined.GridView else Icons.AutoMirrored.Outlined.ViewList,
                when (columns) {
                    1 -> "Show grid"
                    4 -> "Show list"
                    else -> "Increase grid columns"
                },
            ) { vm.cycleColumns() }
            HeaderGlyph(Icons.Outlined.Add, "Add a source", onClick = onAddSource)
            HeaderGlyph(Icons.Outlined.Settings, "Settings", onClick = onOpenSettings)
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
        FacetRow(facet) { selected -> savedList = null; vm.setFacet(selected) }
        Spacer(Modifier.size(headerGap))

        val drillNow = drill
        when {
            savedList != null -> Column(Modifier.fillMaxSize()) {
                val list = savedList!!
                Row(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.S)) {
                    Text("‹ Back", style = HearthText.Label, color = palette.ember, modifier = Modifier.clickable { savedList = null })
                    Spacer(Modifier.width(Hearth.Spacing.M))
                    Text(list.title, style = hearthDisplay(20.sp, FontWeight.SemiBold), color = palette.text)
                }
                val items = savedBooks[list].orEmpty()
                if (items.isEmpty()) BrowseEmptyState("Nothing saved yet", "Save a book from its details to find it here.")
                else BookGrid(items, columns, vm, selectionMode, selection, onSelectBook, onPlayBook)
            }
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
                BookGrid(
                    books, columns, vm, selectionMode, selection, onSelectBook, onPlayBook,
                    hasLibraryBooks = total > 0,
                    onAddSource = onAddSource,
                )
            }

            facet == LibraryFacet.SERIES && series.isEmpty() -> BrowseEmptyState(
                "No series yet",
                "Books with series details from your servers will be grouped here.",
            )
            facet == LibraryFacet.SERIES -> BrowseLayout(series, columns) { vm.openSeries(it.name) }
            facet == LibraryFacet.AUTHORS && authors.isEmpty() -> BrowseEmptyState(
                "No authors yet",
                "Books with author details from your servers will be grouped here.",
            )
            facet == LibraryFacet.AUTHORS -> BrowseLayout(authors, columns) { vm.openAuthor(it.name) }
            facet == LibraryFacet.NARRATORS && narrators.isEmpty() -> BrowseEmptyState(
                "No narrators yet",
                "Audiobooks with narrator details from your servers will be grouped here.",
            )
            facet == LibraryFacet.NARRATORS -> BrowseLayout(narrators, columns) { vm.openNarrator(it.name) }
            facet == LibraryFacet.SHELVES -> Column(Modifier.fillMaxSize()) {
                Row(
                    Modifier.fillMaxWidth().clickable { showPersonalCollections = true }
                        .padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.M),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.Folder, null, tint = palette.ember, modifier = Modifier.size(28.dp))
                    Text("Personal collections", style = HearthText.Label, color = palette.text,
                        modifier = Modifier.weight(1f).padding(start = Hearth.Spacing.M))
                    Text("Open", style = HearthText.Caption, color = palette.textSecondary)
                }
                Overline("SAVED BOOKS", modifier = Modifier.padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.S))
                SavedBookList.entries.forEach { list ->
                    Row(
                        Modifier.fillMaxWidth().clickable { savedList = list }
                            .padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.M),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(list.title, style = HearthText.Label, color = palette.text, modifier = Modifier.weight(1f))
                        Text("${savedBooks[list].orEmpty().size}", style = HearthText.Caption, color = palette.textSecondary)
                    }
                }
                when {
                shelvesLoading -> BrowseLoadingState()
                shelves.isEmpty() && bookOrbitAdminConnections.isEmpty() -> if (hasGrimmoryConnection) {
                    BrowseEmptyState("No shelves found", "Create a shelf in Grimmory, then refresh.")
                } else {
                    BrowseEmptyState("No server collections found", "BookOrbit collections and Grimmory shelves will appear here.")
                }
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
    }

    if (showFilterSort) {
        FilterSortSheet(vm = vm, onDismiss = { showFilterSort = false })
    }

    if (selectionMode) {
        BulkActionBar(
            count = selection.size,
            canDownload = (drill?.books ?: books).any { it.uniqueKey in selection && it.source != BookSource.LOCAL },
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
