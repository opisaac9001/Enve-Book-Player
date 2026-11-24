package com.enve.hearth.bookorbit

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.engine.bookorbit.BookOrbitBookDropApproval
import com.enve.engine.bookorbit.BookOrbitBookDropEdit
import com.enve.engine.bookorbit.BookOrbitBookDropItem
import com.enve.engine.bookorbit.BookOrbitBookDropLibrary
import com.enve.engine.bookorbit.BookOrbitBookDropMetadata
import com.enve.engine.bookorbit.BookOrbitBookDropStatus
import com.enve.engine.bookorbit.BookOrbitFailureReason
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.shell.profileViewModel

@Composable
fun BookOrbitBookDropScreen(
    initialAccountId: String?,
    onBack: () -> Unit,
) {
    val vm: BookOrbitBookDropViewModel = profileViewModel()
    LaunchedEffect(initialAccountId) { initialAccountId?.let(vm::selectAccount) }
    val accounts by vm.accounts.collectAsStateWithLifecycle()
    val accountId by vm.activeAccountId.collectAsStateWithLifecycle()
    val state by vm.state.collectAsStateWithLifecycle()
    val items by vm.items.collectAsStateWithLifecycle()
    val itemsFailure by vm.itemsFailure.collectAsStateWithLifecycle()
    val searchInput by vm.searchInput.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    val ready = state.phase == BookOrbitBookDropPhase.READY
    val idle = state.busy == null
    var pendingDiscard by remember { mutableStateOf<List<Int>?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { vm.importFile(it.toString()) }
    }
    val reviewItem = state.reviewId?.let { id -> items.items.firstOrNull { it.id == id } }
    BackHandler(enabled = reviewItem != null) { vm.closeReview() }

    Box(Modifier.fillMaxSize().background(palette.bg)) {
        if (reviewItem != null) {
            BookDropReview(
                item = reviewItem,
                libraries = state.libraries,
                librariesFailed = state.librariesFailed,
                canApprove = state.canApprove,
                busy = state.busy,
                onBack = vm::closeReview,
                onRetryLibraries = vm::loadLibraries,
                onSave = { edit -> vm.save(reviewItem.id, edit) },
                onApplyFetched = { vm.applyFetched(listOf(reviewItem.id)) },
                onApprove = { edit -> vm.approve(listOf(reviewItem.id), edit?.let { reviewItem.id to it }) },
                onDiscard = { pendingDiscard = listOf(reviewItem.id) },
            )
        } else {
            BookOrbitScreen(
                overline = "BookOrbit",
                title = "Book Drop",
                accounts = accounts,
                selectedAccountId = accountId,
                onSelectAccount = vm::selectAccount,
                onBack = onBack,
                trailing = {
                    HeaderAction(
                        icon = Icons.Outlined.Refresh,
                        description = "Refresh Book Drop",
                        enabled = ready && idle && !items.loading,
                        tag = "bookorbit-bookdrop-refresh",
                        onClick = vm::refresh,
                    )
                    HeaderAction(
                        icon = Icons.Outlined.UploadFile,
                        description = "Import a file into Book Drop",
                        enabled = ready && idle,
                        tag = "bookorbit-bookdrop-import",
                        onClick = { picker.launch(arrayOf("*/*")) },
                    )
                },
            ) {
                Column(Modifier.weight(1f).fillMaxWidth()) {
                    when (state.phase) {
                        BookOrbitBookDropPhase.LOADING -> BookOrbitLoadingBlock()
                        BookOrbitBookDropPhase.NO_ACCOUNT -> BookOrbitPlaceholder(
                            headline = "No BookOrbit account",
                            body = "Add a BookOrbit source to review the files waiting in its Book Drop.",
                        )
                        BookOrbitBookDropPhase.DENIED -> BookOrbitPlaceholder(
                            headline = "Book Drop isn't open to this account",
                            body = "BookOrbit calls this the Library Dock. This account doesn't have the Library Dock permission, so nothing can be listed or imported. Ask the server admin to grant it.",
                            onRetry = vm::retry,
                        )
                        BookOrbitBookDropPhase.FAILED -> {
                            val reason = state.failure ?: BookOrbitFailureReason.UNREACHABLE
                            BookOrbitPlaceholder(headline = reason.headline(), body = reason.explanation(), onRetry = vm::retry)
                        }
                        BookOrbitBookDropPhase.READY -> BookDropInbox(
                            state = state,
                            items = items,
                            failure = itemsFailure,
                            searchInput = searchInput,
                            onSearch = vm::setSearch,
                            onFilter = vm::setStatusFilter,
                            onRetry = vm::refresh,
                            onLoadMore = vm::loadMore,
                            onToggle = vm::toggleSelected,
                            onOpen = vm::openReview,
                            onImport = { picker.launch(arrayOf("*/*")) },
                        )
                    }
                }
                if (ready && state.selection.isNotEmpty()) {
                    SelectionBar(
                        count = state.selection.size,
                        canApprove = state.canApprove,
                        busy = state.busy,
                        onApprove = { vm.approve(state.selection.toList()) },
                        onDiscard = { pendingDiscard = state.selection.toList() },
                        onClear = vm::clearSelection,
                    )
                }
            }
        }

        state.notice?.let { message ->
            LaunchedEffect(message) {
                kotlinx.coroutines.delay(5_000)
                vm.dismissNotice()
            }
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.XXXL)
                    .clip(RoundedCornerShape(Hearth.Radius.Inner))
                    .background(palette.bgElevated)
                    .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Inner))
                    .padding(horizontal = 18.dp, vertical = 10.dp)
                    .testTag("bookorbit-bookdrop-notice"),
            ) {
                Text(message, style = HearthText.Caption, color = palette.text)
            }
        }
    }

    pendingDiscard?.let { ids ->
        AlertDialog(
            onDismissRequest = { pendingDiscard = null },
            title = { Text(if (ids.size == 1) "Discard this file?" else "Discard ${ids.size} files?") },
            text = { Text("BookOrbit deletes discarded files from its Book Drop. They aren't added to any library and this can't be undone.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        vm.discard(ids)
                        pendingDiscard = null
                    },
                    modifier = Modifier.testTag("bookorbit-bookdrop-discard-confirm"),
                ) { Text("Discard", color = palette.statusError) }
            },
            dismissButton = { TextButton(onClick = { pendingDiscard = null }) { Text("Cancel") } },
            containerColor = palette.bgElevated,
            titleContentColor = palette.text,
            textContentColor = palette.textSecondary,
        )
    }

    state.approval?.let { approval -> ApprovalDialog(approval, vm::dismissApproval) }
}

@Composable
private fun HeaderAction(
    icon: ImageVector,
    description: String,
    enabled: Boolean,
    tag: String,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    Box(
        Modifier
            .size(48.dp)
            .clip(CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .testTag(tag),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = description,
            tint = if (enabled) palette.text else palette.textTertiary,
            modifier = Modifier.size(22.dp),
        )
    }
}

@Composable
private fun ColumnScope.BookDropInbox(
    state: BookOrbitBookDropState,
    items: BookOrbitPagedList<BookOrbitBookDropItem>,
    failure: BookOrbitFailureReason?,
    searchInput: String,
    onSearch: (String) -> Unit,
    onFilter: (BookOrbitBookDropStatus?) -> Unit,
    onRetry: () -> Unit,
    onLoadMore: () -> Unit,
    onToggle: (Int) -> Unit,
    onOpen: (Int) -> Unit,
    onImport: () -> Unit,
) {
    val palette = Hearth.palette
    val busyLabel = when (state.busy) {
        BookOrbitBookDropBusy.IMPORTING -> "Uploading the file to BookOrbit…"
        BookOrbitBookDropBusy.SAVING -> "Saving changes…"
        BookOrbitBookDropBusy.APPLYING -> "Applying fetched details…"
        BookOrbitBookDropBusy.APPROVING -> "Adding to the library…"
        BookOrbitBookDropBusy.DISCARDING -> "Discarding…"
        null -> null
    }
    val summaryLine = busyLabel ?: state.summary?.let { summary ->
        listOfNotNull(
            "${summary.total} waiting",
            "${summary.ready} ready".takeIf { summary.ready > 0 },
            "${summary.needsReview} need review".takeIf { summary.needsReview > 0 },
            "${summary.error} failed".takeIf { summary.error > 0 },
            "processing paused".takeIf { summary.paused },
        ).joinToString(" · ")
    }
    summaryLine?.let { line ->
        Text(
            line,
            style = HearthText.Caption,
            color = palette.textSecondary,
            modifier = Modifier
                .padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.XS)
                .testTag("bookorbit-bookdrop-summary"),
        )
    }
    if (!state.canApprove) {
        Text(
            "This account can stage and review files. Adding them to a library needs BookOrbit's Upload books permission.",
            style = HearthText.Caption,
            color = palette.statusWarn,
            modifier = Modifier.padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.XS),
        )
    }
    TextField(
        value = searchInput,
        onValueChange = onSearch,
        placeholder = { Text("Search file names and titles", style = HearthText.Body) },
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.S)
            .testTag("bookorbit-bookdrop-search"),
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
    LazyRow(
        contentPadding = PaddingValues(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.XS),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        item { HearthChip("All", state.statusFilter == null, { onFilter(null) }, Modifier.testTag("bookorbit-bookdrop-filter-all")) }
        item {
            HearthChip(
                "Processing",
                state.statusFilter == BookOrbitBookDropStatus.PENDING,
                { onFilter(BookOrbitBookDropStatus.PENDING) },
                Modifier.testTag("bookorbit-bookdrop-filter-pending"),
            )
        }
        item {
            HearthChip(
                "Ready",
                state.statusFilter == BookOrbitBookDropStatus.READY,
                { onFilter(BookOrbitBookDropStatus.READY) },
                Modifier.testTag("bookorbit-bookdrop-filter-ready"),
            )
        }
        item {
            HearthChip(
                "Failed",
                state.statusFilter == BookOrbitBookDropStatus.ERROR,
                { onFilter(BookOrbitBookDropStatus.ERROR) },
                Modifier.testTag("bookorbit-bookdrop-filter-error"),
            )
        }
    }
    when {
        items.failure == BookOrbitPageFailure.FIRST_PAGE -> {
            val reason = failure ?: BookOrbitFailureReason.UNREACHABLE
            BookOrbitPlaceholder(headline = reason.headline(), body = reason.explanation(), onRetry = onRetry)
        }
        items.showsFirstLoad || items.loadedPages == 0 -> BookOrbitLoadingBlock()
        items.items.isEmpty() -> {
            val filtered = state.statusFilter != null || searchInput.isNotBlank()
            BookOrbitPlaceholder(
                headline = if (filtered) "Nothing matches" else "Book Drop is empty",
                body = if (filtered) {
                    "No staged file matches that filter or search."
                } else {
                    "Import a file from this device, or drop one into the server's Book Drop folder, and it will wait here for review."
                },
            )
            if (!filtered) {
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    OutlinedButton(
                        onClick = onImport,
                        enabled = state.busy == null,
                        modifier = Modifier.testTag("bookorbit-bookdrop-import-empty"),
                    ) { Text("Import a file") }
                }
            }
        }
        else -> {
            if (items.failure == BookOrbitPageFailure.REFRESH) {
                BookOrbitInlineError(
                    message = "Couldn't refresh Book Drop. Showing the last list.",
                    onRetry = onRetry,
                    tag = "bookorbit-bookdrop-refresh-error",
                )
            }
            val total = items.total ?: items.items.size
            Text(
                if (total == 1) "1 file" else "$total files",
                style = HearthText.Caption,
                color = palette.textTertiary,
                modifier = Modifier
                    .padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.XS)
                    .testTag("bookorbit-bookdrop-total"),
            )
            val listState = rememberLazyListState()
            val nearEnd by remember {
                derivedStateOf {
                    val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
                    last >= listState.layoutInfo.totalItemsCount - 4
                }
            }
            val autoLoad = items.canLoadMore && items.failure == null
            LaunchedEffect(nearEnd, autoLoad, items.items.size) {
                if (nearEnd && autoLoad) onLoadMore()
            }
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth().testTag("bookorbit-bookdrop-list"),
                contentPadding = PaddingValues(
                    start = Hearth.Spacing.XL,
                    top = Hearth.Spacing.XS,
                    end = Hearth.Spacing.XL,
                    bottom = Hearth.Spacing.XXL,
                ),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                items(items.items, key = { it.id }) { item ->
                    BookDropRow(
                        item = item,
                        selected = item.id in state.selection,
                        enabled = state.busy == null,
                        onToggle = { onToggle(item.id) },
                        onOpen = { onOpen(item.id) },
                    )
                }
                item {
                    BookOrbitPageFooter(
                        list = items,
                        noun = "files",
                        onLoadMore = onLoadMore,
                        tag = "bookorbit-bookdrop-more",
                    )
                }
            }
        }
    }
}

@Composable
private fun BookDropRow(
    item: BookOrbitBookDropItem,
    selected: Boolean,
    enabled: Boolean,
    onToggle: () -> Unit,
    onOpen: () -> Unit,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Inner)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, if (selected) palette.ember else palette.hairline, shape)
            .testTag("bookorbit-bookdrop-item-${item.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(
            checked = selected,
            onCheckedChange = { onToggle() },
            enabled = enabled,
            colors = CheckboxDefaults.colors(
                checkedColor = palette.ember,
                uncheckedColor = palette.textSecondary,
                checkmarkColor = palette.readableOnEmber,
            ),
            modifier = Modifier.testTag("bookorbit-bookdrop-select-${item.id}"),
        )
        Column(
            Modifier
                .weight(1f)
                .clickable(role = Role.Button, onClickLabel = "Review ${item.fileName}", onClick = onOpen)
                .padding(vertical = Hearth.Spacing.M)
                .padding(end = Hearth.Spacing.M),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS),
        ) {
            Text(
                item.metadata.title.ifBlank { item.fileName },
                style = HearthText.Label,
                color = palette.text,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                listOfNotNull(
                    item.metadata.authors.joinToString(", ").takeIf { it.isNotBlank() },
                    item.fileName.takeIf { item.metadata.title.isNotBlank() },
                    item.format?.uppercase(),
                    bookDropFileSize(item.fileSizeBytes),
                ).joinToString(" · "),
                style = HearthText.Caption,
                color = palette.textSecondary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                bookDropStatusLabel(item),
                style = HearthText.Caption.copy(fontWeight = FontWeight.Medium),
                color = if (bookDropNeedsAttention(item)) palette.statusError else palette.textSecondary,
            )
            item.errorMessage?.let { message ->
                Text(message, style = HearthText.Caption, color = palette.statusError, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            if (item.alsoIn.isNotEmpty()) {
                Text(
                    "Also in ${item.alsoIn.joinToString(", ")}",
                    style = HearthText.Caption,
                    color = palette.statusWarn,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun SelectionBar(
    count: Int,
    canApprove: Boolean,
    busy: BookOrbitBookDropBusy?,
    onApprove: () -> Unit,
    onDiscard: () -> Unit,
    onClear: () -> Unit,
) {
    val palette = Hearth.palette
    Row(
        Modifier
            .fillMaxWidth()
            .background(palette.bgElevated)
            .navigationBarsPadding()
            .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.XS)
            .testTag("bookorbit-bookdrop-selection"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "$count selected",
            style = HearthText.Label,
            color = palette.text,
            modifier = Modifier.weight(1f),
        )
        TextButton(onClick = onClear, enabled = busy == null) { Text("Clear", color = palette.textSecondary) }
        TextButton(
            onClick = onDiscard,
            enabled = busy == null,
            modifier = Modifier.testTag("bookorbit-bookdrop-discard-selected"),
        ) { Text("Discard", color = if (busy == null) palette.statusError else palette.textTertiary) }
        TextButton(
            onClick = onApprove,
            enabled = canApprove && busy == null,
            modifier = Modifier.testTag("bookorbit-bookdrop-approve-selected"),
        ) {
            Text(
                if (busy == BookOrbitBookDropBusy.APPROVING) "Adding…" else "Add to library",
                color = if (canApprove && busy == null) palette.ember else palette.textTertiary,
            )
        }
    }
}

@Composable
private fun BookDropReview(
    item: BookOrbitBookDropItem,
    libraries: List<BookOrbitBookDropLibrary>,
    librariesFailed: Boolean,
    canApprove: Boolean,
    busy: BookOrbitBookDropBusy?,
    onBack: () -> Unit,
    onRetryLibraries: () -> Unit,
    onSave: (BookOrbitBookDropEdit) -> Unit,
    onApplyFetched: () -> Unit,
    onApprove: (BookOrbitBookDropEdit?) -> Unit,
    onDiscard: () -> Unit,
) {
    val palette = Hearth.palette
    var form by remember(item.id, item.metadata, item.targetLibraryId, item.targetFolderId) {
        mutableStateOf(BookOrbitBookDropForm(item))
    }
    val changes = form.changes(item)
    val idle = busy == null
    val library = libraries.firstOrNull { it.id == form.libraryId }

    Column(Modifier.fillMaxSize().background(palette.bg).testTag("bookorbit-bookdrop-review")) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(48.dp).clip(CircleShape).clickable(role = Role.Button, onClick = onBack),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Outlined.ArrowBack,
                    contentDescription = "Back to Book Drop",
                    tint = palette.text,
                    modifier = Modifier.size(26.dp),
                )
            }
            Column(Modifier.weight(1f).padding(start = Hearth.Spacing.S)) {
                Overline("Book Drop")
                Text(item.fileName, style = HearthText.BookTitle, color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        Column(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Hearth.Spacing.XL)
                .padding(bottom = Hearth.Spacing.XXL),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
        ) {
            BookOrbitCard("File") {
                BookOrbitDetailRow("Status", bookDropStatusLabel(item))
                item.format?.let { BookOrbitDetailRow("Format", it.uppercase()) }
                bookDropFileSize(item.fileSizeBytes)?.let { BookOrbitDetailRow("Size", it) }
                item.confidence?.let { BookOrbitDetailRow("Match confidence", "${it.toInt()}%") }
                item.errorMessage?.let { Text(it, style = HearthText.Caption, color = palette.statusError) }
                item.formerLibraryName?.let {
                    Text("Its library, $it, was removed. Choose a new destination.", style = HearthText.Caption, color = palette.statusWarn)
                }
                if (item.alsoIn.isNotEmpty()) {
                    Text("Already held by ${item.alsoIn.joinToString(", ")}.", style = HearthText.Caption, color = palette.statusWarn)
                }
            }

            BookOrbitCard("Details", caption = if (item.edited) "Includes your edits" else "What BookOrbit will file this as") {
                ReviewField("Title", form.title, "bookorbit-bookdrop-field-title") { form = form.copy(title = it) }
                ReviewField("Subtitle", form.subtitle, "bookorbit-bookdrop-field-subtitle") { form = form.copy(subtitle = it) }
                ReviewField("Authors, separated by commas", form.authors, "bookorbit-bookdrop-field-authors") { form = form.copy(authors = it) }
                ReviewField("Narrators, separated by commas", form.narrators, "bookorbit-bookdrop-field-narrators") { form = form.copy(narrators = it) }
                ReviewField("Series", form.seriesName, "bookorbit-bookdrop-field-series") { form = form.copy(seriesName = it) }
                ReviewField(
                    label = "Number in series",
                    value = form.seriesIndex,
                    tag = "bookorbit-bookdrop-field-series-index",
                    keyboardType = KeyboardType.Decimal,
                    error = "Use a number such as 2 or 2.5".takeIf { !form.seriesIndexValid },
                ) { form = form.copy(seriesIndex = it) }
                ReviewField("Publisher", form.publisher, "bookorbit-bookdrop-field-publisher") { form = form.copy(publisher = it) }
                ReviewField(
                    label = "Year published",
                    value = form.year,
                    tag = "bookorbit-bookdrop-field-year",
                    keyboardType = KeyboardType.Number,
                    error = "Use a four-digit year".takeIf { !form.yearValid },
                ) { form = form.copy(year = it) }
                ReviewField("Language", form.language, "bookorbit-bookdrop-field-language") { form = form.copy(language = it) }
                ReviewField("ISBN-13", form.isbn13, "bookorbit-bookdrop-field-isbn", KeyboardType.Number) { form = form.copy(isbn13 = it) }
                ReviewField("Genres, separated by commas", form.genres, "bookorbit-bookdrop-field-genres") { form = form.copy(genres = it) }
                ReviewField(
                    label = "Description",
                    value = form.description,
                    tag = "bookorbit-bookdrop-field-description",
                    singleLine = false,
                ) { form = form.copy(description = it) }
            }

            BookOrbitCard("Fetched details", caption = "Looked up by BookOrbit") {
                val fetched = item.fetched
                if (fetched == null) {
                    Text("BookOrbit hasn't found any details for this file.", style = HearthText.Body, color = palette.textSecondary)
                } else {
                    MetadataSummary(fetched)
                    OutlinedButton(
                        onClick = onApplyFetched,
                        enabled = idle,
                        modifier = Modifier.fillMaxWidth().testTag("bookorbit-bookdrop-apply-fetched"),
                    ) { Text(if (busy == BookOrbitBookDropBusy.APPLYING) "Applying…" else "Use fetched details") }
                    if (item.edited) {
                        Text(
                            "BookOrbit keeps details you've edited by hand, so applying may leave this file unchanged.",
                            style = HearthText.Caption,
                            color = palette.textTertiary,
                        )
                    }
                }
            }

            BookOrbitCard("Embedded in the file") {
                val embedded = item.embedded
                if (embedded == null) {
                    Text("The file carries no details of its own.", style = HearthText.Body, color = palette.textSecondary)
                } else {
                    MetadataSummary(embedded)
                }
            }

            BookOrbitCard("Destination", caption = "The library and folder this file is added to") {
                when {
                    librariesFailed -> BookOrbitInlineError(
                        message = "Couldn't load this server's libraries.",
                        onRetry = onRetryLibraries,
                        tag = "bookorbit-bookdrop-libraries-error",
                    )
                    libraries.isEmpty() -> Text(
                        "This account can't see any library to file into.",
                        style = HearthText.Body,
                        color = palette.textSecondary,
                    )
                    else -> {
                        Picker(
                            label = "Library",
                            value = library?.name ?: "Choose a library",
                            options = libraries.map { it.id to it.name },
                            tag = "bookorbit-bookdrop-library",
                            enabled = idle,
                        ) { id ->
                            val chosen = libraries.first { it.id == id }
                            form = form.copy(libraryId = id, folderId = chosen.folders.singleOrNull()?.id)
                        }
                        if (library != null) {
                            if (library.folders.isEmpty()) {
                                Text("That library has no folder to file into.", style = HearthText.Caption, color = palette.statusWarn)
                            } else {
                                Picker(
                                    label = "Folder",
                                    value = library.folders.firstOrNull { it.id == form.folderId }?.path ?: "Choose a folder",
                                    options = library.folders.map { it.id to it.path },
                                    tag = "bookorbit-bookdrop-folder",
                                    enabled = idle,
                                ) { id -> form = form.copy(folderId = id) }
                            }
                            val format = item.format?.lowercase()
                            if (format != null && library.allowedFormats.isNotEmpty() &&
                                library.allowedFormats.none { it.equals(format, ignoreCase = true) }
                            ) {
                                Text(
                                    "${library.name} doesn't accept ${format.uppercase()} files.",
                                    style = HearthText.Caption,
                                    color = palette.statusWarn,
                                )
                            }
                        }
                    }
                }
            }

            OutlinedButton(
                onClick = { changes?.let(onSave) },
                enabled = idle && changes != null && form.valid,
                modifier = Modifier.fillMaxWidth().testTag("bookorbit-bookdrop-save"),
            ) { Text(if (busy == BookOrbitBookDropBusy.SAVING) "Saving…" else "Save changes") }

            val approvable = canApprove && item.status == BookOrbitBookDropStatus.READY && form.hasDestination && form.valid
            OutlinedButton(
                onClick = { onApprove(changes) },
                enabled = idle && approvable,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.ember),
                modifier = Modifier.fillMaxWidth().testTag("bookorbit-bookdrop-approve"),
            ) { Text(if (busy == BookOrbitBookDropBusy.APPROVING) "Adding…" else "Add to library") }
            if (!approvable) {
                Text(
                    when {
                        !canApprove -> "Adding to a library needs BookOrbit's Upload books permission."
                        item.status != BookOrbitBookDropStatus.READY -> "BookOrbit can add this file once it has finished processing without errors."
                        !form.hasDestination -> "Choose a library and folder first."
                        else -> "Fix the highlighted fields first."
                    },
                    style = HearthText.Caption,
                    color = palette.textTertiary,
                )
            }

            OutlinedButton(
                onClick = onDiscard,
                enabled = idle,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.statusError),
                modifier = Modifier.fillMaxWidth().testTag("bookorbit-bookdrop-discard"),
            ) { Text("Discard file") }
        }
    }
}

@Composable
private fun ReviewField(
    label: String,
    value: String,
    tag: String,
    keyboardType: KeyboardType = KeyboardType.Text,
    singleLine: Boolean = true,
    error: String? = null,
    onValueChange: (String) -> Unit,
) {
    val supportingText: (@Composable () -> Unit)? = if (error == null) null else { { Text(error) } }
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = singleLine,
        minLines = if (singleLine) 1 else 3,
        isError = error != null,
        supportingText = supportingText,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        modifier = Modifier.fillMaxWidth().testTag(tag),
    )
}

@Composable
private fun MetadataSummary(metadata: BookOrbitBookDropMetadata) {
    val rows = listOfNotNull(
        metadata.title.takeIf { it.isNotBlank() }?.let { "Title" to it },
        metadata.authors.joinToString(", ").takeIf { it.isNotBlank() }?.let { "Authors" to it },
        metadata.seriesName.takeIf { it.isNotBlank() }?.let { name ->
            "Series" to listOfNotNull(name, metadata.seriesIndex.takeIf { it.isNotBlank() }?.let { "#$it" }).joinToString(" ")
        },
        metadata.publisher.takeIf { it.isNotBlank() }?.let { "Publisher" to it },
        metadata.publishedYear?.let { "Year" to it.toString() },
        metadata.language.takeIf { it.isNotBlank() }?.let { "Language" to it },
        metadata.isbn13.takeIf { it.isNotBlank() }?.let { "ISBN-13" to it },
    )
    if (rows.isEmpty()) {
        Text("No usable details.", style = HearthText.Body, color = Hearth.palette.textSecondary)
    } else {
        rows.forEach { (label, value) -> BookOrbitDetailRow(label, value) }
    }
}

@Composable
private fun Picker(
    label: String,
    value: String,
    options: List<Pair<Int, String>>,
    tag: String,
    enabled: Boolean,
    onSelect: (Int) -> Unit,
) {
    val palette = Hearth.palette
    var expanded by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Inner)
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(shape)
                .border(1.dp, palette.hairline, shape)
                .clickable(enabled = enabled, role = Role.DropdownList, onClickLabel = "Choose $label") { expanded = true }
                .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M)
                .testTag(tag),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Overline(label)
                Text(value, style = HearthText.Label, color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            Icon(Icons.Outlined.ExpandMore, contentDescription = null, tint = palette.textSecondary)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { (id, name) ->
                DropdownMenuItem(
                    text = { Text(name) },
                    onClick = {
                        expanded = false
                        onSelect(id)
                    },
                    modifier = Modifier.testTag("$tag-$id"),
                )
            }
        }
    }
}

@Composable
private fun ApprovalDialog(approval: BookOrbitBookDropApproval, onDismiss: () -> Unit) {
    val palette = Hearth.palette
    val problems = approval.results.filterNot { it.success }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(bookDropApprovalHeadline(approval)) },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()).testTag("bookorbit-bookdrop-approval"),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                if (problems.isEmpty()) {
                    Text(
                        if (approval.total == 0) "BookOrbit found nothing it could add." else "Every selected file is now in its library.",
                        color = palette.textSecondary,
                    )
                } else {
                    Text(
                        if (approval.succeeded > 0) "These files were left in Book Drop:" else "Nothing was added. These files are still in Book Drop:",
                        color = palette.textSecondary,
                    )
                    problems.forEach { result ->
                        Column {
                            Text(result.fileName, style = HearthText.Label, color = palette.text)
                            Text(
                                when {
                                    result.duplicate -> result.message ?: "The library already holds this book."
                                    else -> result.message ?: "BookOrbit gave no reason."
                                },
                                style = HearthText.Caption,
                                color = if (result.duplicate) palette.statusWarn else palette.statusError,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.testTag("bookorbit-bookdrop-approval-done")) { Text("Done") }
        },
        containerColor = palette.bgElevated,
        titleContentColor = palette.text,
        textContentColor = palette.textSecondary,
    )
}
