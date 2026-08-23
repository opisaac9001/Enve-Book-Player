package com.enve.app.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DriveFileRenameOutline
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material.icons.filled.RestartAlt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.app.ui.components.BookSourceIcon
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsNavigationRow
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.SettingsSectionHeader
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.StorytellerHubState
import com.enve.app.viewmodel.StorytellerHubViewModel
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.storyteller.StorytellerProcessRestart
import com.enve.storyteller.dto.StorytellerAlignmentReportDto
import com.enve.storyteller.dto.StorytellerBookDto
import com.enve.storyteller.dto.StorytellerShelfDto
import com.enve.storyteller.storytellerProcessingActive
import com.enve.hearth.design.hearthDisplay
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonNull

private val StorytellerTint = Color(0xFF5B8DBE)
private val StorytellerRed = Color(0xFFB3453E)
private const val MaxVisibleProcessBooks = 30
private const val MaxVisibleShelfBooks = 50
private val ALIGNMENT_GRADE_ORDER = listOf("A+", "A", "A-", "B", "B-", "C", "D", "F")

@Composable
fun StorytellerHubScreen(
    onBack: () -> Unit,
    onConnectStoryteller: () -> Unit,
    viewModel: StorytellerHubViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsState()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val reportOpen = state.report != null || state.reportLoading
    val activeProcessingKey = state.candidates
        .filter { storytellerProcessingActive(it.readaloud) }
        .joinToString(",") { it.uuid }

    var creatingShelf by remember { mutableStateOf(false) }
    var renamingShelf by remember { mutableStateOf<StorytellerShelfDto?>(null) }
    var deletingShelf by remember { mutableStateOf<StorytellerShelfDto?>(null) }
    var editingShelfId by remember { mutableStateOf<String?>(null) }
    var restartRequest by remember { mutableStateOf<Pair<StorytellerBookDto, StorytellerProcessRestart>?>(null) }
    var cancellingBook by remember { mutableStateOf<StorytellerBookDto?>(null) }
    val editingShelf = state.shelves.firstOrNull { it.uuid == editingShelfId }

    BackHandler(enabled = reportOpen || editingShelf != null) {
        if (reportOpen) viewModel.closeReport() else editingShelfId = null
    }

    LaunchedEffect(activeProcessingKey, state.selectedConnectionId) {
        if (activeProcessingKey.isEmpty()) return@LaunchedEffect
        while (true) {
            delay(5_000)
            viewModel.refreshProcessing()
        }
    }

    SettingsScreenLayout(animatedBackground = EnveTheme.dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .statusBarsPadding()
                .padding(bottom = DS.Spacing.XXL.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = {
                    when {
                        reportOpen -> viewModel.closeReport()
                        editingShelf != null -> editingShelfId = null
                        else -> onBack()
                    }
                })
                Text(
                    text = when {
                        reportOpen -> "Alignment report"
                        editingShelf != null -> "Shelf books"
                        else -> "Storyteller"
                    },
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
                Spacer(modifier = Modifier.weight(1f))
                if (!reportOpen && editingShelf == null) {
                    TextButton(onClick = viewModel::refresh, enabled = state.selectedConnection != null && !state.isLoading) {
                        Icon(Icons.Default.Refresh, contentDescription = null, tint = StorytellerTint)
                        Text("Refresh", color = StorytellerTint)
                    }
                }
            }

            state.message?.let { message ->
                NoticeRowCard(text = message, actionLabel = "Dismiss", onAction = viewModel::clearMessage)
            }

            if (reportOpen) {
                if (state.reportLoading) {
                    LoadingRowCard("Loading alignment report")
                } else {
                    state.report?.let { ReportContent(it) }
                }
            } else if (editingShelf != null) {
                ShelfMembershipContent(
                    state = state,
                    shelf = editingShelf,
                    onSave = { viewModel.updateShelfBooks(editingShelf, it) },
                )
            } else {
                HubHero(state)

                if (state.storytellerConnections.isEmpty()) {
                    NoConnectionCard(onConnectStoryteller)
                } else {
                    if (state.storytellerConnections.size > 1) {
                        ConnectionPicker(
                            connections = state.storytellerConnections,
                            selectedId = state.selectedConnectionId,
                            onSelect = viewModel::selectConnection,
                        )
                    }

                    if (state.isLoading && !state.loadedAnything) {
                        LoadingRowCard("Loading Storyteller data")
                    }

                    ShelvesCard(
                        state = state,
                        onCreate = { creatingShelf = true },
                        onRename = { renamingShelf = it },
                        onDelete = { deletingShelf = it },
                        onManage = { editingShelfId = it.uuid },
                    )

                    AlignmentQualityCard(state)

                    ProcessingCard(
                        state = state,
                        onOpenReport = viewModel::openReport,
                        onContinue = { viewModel.startProcessing(it.uuid, null) },
                        onRestartSync = { restartRequest = it to StorytellerProcessRestart.SYNC },
                        onRestartTranscription = { restartRequest = it to StorytellerProcessRestart.TRANSCRIPTION },
                        onFullRestart = { restartRequest = it to StorytellerProcessRestart.FULL },
                        onCancel = { cancellingBook = it },
                    )
                }
            }
        }
    }

    if (creatingShelf) {
        ShelfEditDialog(
            title = "New shelf",
            confirmLabel = "Create",
            withDescription = true,
            onDismiss = { creatingShelf = false },
            onConfirm = { name, description ->
                viewModel.createShelf(name, description)
                creatingShelf = false
            },
        )
    }
    renamingShelf?.let { shelf ->
        ShelfEditDialog(
            title = "Rename shelf",
            confirmLabel = "Save",
            initialName = shelf.name,
            onDismiss = { renamingShelf = null },
            onConfirm = { name, _ ->
                viewModel.renameShelf(shelf, name)
                renamingShelf = null
            },
        )
    }
    deletingShelf?.let { shelf ->
        AlertDialog(
            onDismissRequest = { deletingShelf = null },
            title = { Text("Delete shelf?") },
            text = { Text("Removes '${shelf.name}' from this Storyteller server. Books on the shelf are not deleted.") },
            confirmButton = {
                TextButton(onClick = { viewModel.deleteShelf(shelf); deletingShelf = null }) {
                    Text("Delete", color = StorytellerRed)
                }
            },
            dismissButton = { TextButton(onClick = { deletingShelf = null }) { Text("Cancel") } },
            containerColor = EnveTheme.colors.cardBackground,
        )
    }
    restartRequest?.let { (book, restart) ->
        AlertDialog(
            onDismissRequest = { restartRequest = null },
            title = { Text(restartConfirmationTitle(restart)) },
            text = { Text(restartConfirmationMessage(book, restart)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.startProcessing(book.uuid, restart)
                    restartRequest = null
                }) {
                    Text(
                        "Restart",
                        color = if (restart == StorytellerProcessRestart.SYNC) StorytellerTint else StorytellerRed,
                    )
                }
            },
            dismissButton = { TextButton(onClick = { restartRequest = null }) { Text("Keep current work") } },
            containerColor = EnveTheme.colors.cardBackground,
        )
    }
    cancellingBook?.let { book ->
        AlertDialog(
            onDismissRequest = { cancellingBook = null },
            title = { Text("Cancel alignment?") },
            text = { Text("Storyteller will stop its current work on '${storytellerBookLabel(book)}'.") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.cancelProcessing(book.uuid)
                    cancellingBook = null
                }) { Text("Cancel alignment", color = StorytellerRed) }
            },
            dismissButton = { TextButton(onClick = { cancellingBook = null }) { Text("Keep current work") } },
            containerColor = EnveTheme.colors.cardBackground,
        )
    }
}

private val StorytellerHubState.loadedAnything: Boolean
    get() = shelves.isNotEmpty() || facets != null || candidates.isNotEmpty() ||
        shelvesError != null || alignmentError != null || processingError != null

@Composable
private fun HubHero(state: StorytellerHubState) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DS.Spacing.XL.scaled(metrics)),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
        ) {
            BookSourceIcon(
                source = BookSource.STORYTELLER,
                tint = StorytellerTint,
                modifier = Modifier.height(64.dp.scaled(metrics)),
            )
            Text("Server Hub", color = colors.primaryText, style = hearthDisplay(20.sp))
            Text(
                text = when {
                    state.storytellerConnections.isEmpty() -> "Shelves and alignment tools appear once a Storyteller server is connected."
                    else -> state.selectedConnection?.name ?: "Storyteller"
                },
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
        }
    }
}

@Composable
private fun NoConnectionCard(onConnectStoryteller: () -> Unit) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(DS.Spacing.LG.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        ) {
            Text("No Storyteller server connected", color = colors.primaryText, fontWeight = FontWeight.SemiBold)
            Text(
                "Connect a Storyteller server to manage shelves, review alignment quality, and control readaloud processing.",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
            Button(
                onClick = onConnectStoryteller,
                shape = RoundedCornerShape(999.dp),
                colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = Color.White),
            ) { Text("Connect Storyteller") }
        }
    }
}

@Composable
private fun ConnectionPicker(
    connections: List<ProviderConnection>,
    selectedId: String?,
    onSelect: (String) -> Unit,
) {
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = EnveTheme.colors.separator.copy(alpha = 0.3f)
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = "Active Server")
        connections.forEachIndexed { index, connection ->
            SettingsNavigationRow(
                icon = if (connection.id == selectedId) Icons.Default.CheckCircle else Icons.AutoMirrored.Filled.MenuBook,
                iconTint = StorytellerTint,
                title = connection.name,
                subtitle = connection.serverUrl,
                onClick = { onSelect(connection.id) },
            )
            if (index < connections.lastIndex) HorizontalDivider(color = dividerColor)
        }
    }
}

@Composable
private fun ShelvesCard(
    state: StorytellerHubState,
    onCreate: () -> Unit,
    onRename: (StorytellerShelfDto) -> Unit,
    onDelete: (StorytellerShelfDto) -> Unit,
    onManage: (StorytellerShelfDto) -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SettingsSectionHeader(
                title = "Shelves",
                subtitle = if (state.shelvesError == null) "${state.shelves.size} personal shelves" else null,
                modifier = Modifier.weight(1f),
            )
            if (state.shelvesError == null || state.shelves.isNotEmpty()) {
                TextButton(onClick = onCreate) {
                    Icon(Icons.Default.Add, contentDescription = null, tint = StorytellerTint, modifier = Modifier.size(18.dp))
                    Text("New", color = StorytellerTint)
                }
            }
        }
        when {
            state.shelvesError != null && state.shelves.isEmpty() -> PermissionNotice(
                error = state.shelvesError,
                hint = "Shelves require server support and the bookList permission on this Storyteller account.",
            )
            state.shelves.isEmpty() -> Text(
                "No shelves yet. Create one to group books on this server.",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
            )
            else -> state.shelves.forEachIndexed { index, shelf ->
                ShelfRow(
                    shelf = shelf,
                    onManage = { onManage(shelf) },
                    onRename = { onRename(shelf) },
                    onDelete = { onDelete(shelf) },
                )
                if (index < state.shelves.lastIndex) HorizontalDivider(color = dividerColor)
            }
        }
    }
}

@Composable
private fun ShelfRow(
    shelf: StorytellerShelfDto,
    onManage: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                shelf.name,
                color = colors.primaryText,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val bookCount = shelf.books.orEmpty().size
            Text(
                listOfNotNull(
                    "$bookCount pinned ${if (bookCount == 1) "book" else "books"}",
                    shelf.description?.takeIf { it.isNotBlank() },
                ).joinToString(" · "),
                color = colors.tertiaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onManage) {
            Icon(Icons.AutoMirrored.Filled.MenuBook, contentDescription = "Manage books", tint = StorytellerTint)
        }
        IconButton(onClick = onRename) {
            Icon(Icons.Default.DriveFileRenameOutline, contentDescription = "Rename", tint = StorytellerTint)
        }
        IconButton(onClick = onDelete) {
            Icon(Icons.Default.Delete, contentDescription = "Delete", tint = StorytellerRed)
        }
    }
}

@Composable
private fun ShelfMembershipContent(
    state: StorytellerHubState,
    shelf: StorytellerShelfDto,
    onSave: (List<String>) -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val serverIds = shelf.books.orEmpty().map { it.bookUuid }
    var orderedBookIds by remember(shelf.uuid) { mutableStateOf(serverIds) }
    var baselineBookIds by remember(shelf.uuid) { mutableStateOf(serverIds) }
    var search by remember(shelf.uuid) { mutableStateOf("") }
    val selectedIds = remember(orderedBookIds) { orderedBookIds.toSet() }
    val booksById = remember(state.books) { state.books.associateBy { it.uuid } }
    val matchingBooks = remember(state.books, selectedIds, search) {
        val available = state.books.filterNot { selectedIds.contains(it.uuid) }
        val query = search.trim()
        if (query.isEmpty()) {
            available
        } else {
            available.filter { storytellerBookSearchText(it).contains(query, ignoreCase = true) }
        }
    }
    val visibleBooks = matchingBooks.take(MaxVisibleShelfBooks)
    val busy = state.busyShelfId == shelf.uuid

    LaunchedEffect(serverIds) {
        if (serverIds == orderedBookIds) baselineBookIds = serverIds
    }

    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(DS.Spacing.LG.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
        ) {
            Text(shelf.name, color = colors.primaryText, style = hearthDisplay(20.sp))
            Text(
                "${orderedBookIds.size} ${if (orderedBookIds.size == 1) "pinned book" else "pinned books"}",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
            Button(
                onClick = { onSave(orderedBookIds) },
                enabled = orderedBookIds != baselineBookIds && !busy,
                shape = RoundedCornerShape(999.dp),
                colors = ButtonDefaults.buttonColors(containerColor = StorytellerTint, contentColor = Color.White),
            ) {
                if (busy) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        strokeWidth = 2.dp,
                        color = Color.White,
                    )
                } else {
                    Text(if (orderedBookIds == baselineBookIds) "Up to date" else "Save changes")
                }
            }
        }
    }

    if (shelf.filter != null && shelf.filter !is JsonNull) {
        NoticeRowCard("This smart shelf keeps matching books automatically. Books added here stay pinned alongside those matches.")
    }

    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = "On This Shelf")
        if (orderedBookIds.isEmpty()) {
            Text(
                "No pinned books. Add books below to build this shelf.",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
            )
        } else {
            orderedBookIds.forEachIndexed { index, bookId ->
                val book = booksById[bookId]
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            book?.let(::storytellerBookLabel) ?: bookId,
                            color = colors.primaryText,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        book?.authors?.firstOrNull()?.name?.takeIf { it.isNotBlank() }?.let { author ->
                            Text(
                                author,
                                color = colors.tertiaryText,
                                fontSize = DS.FontSize.Caption.scaled(metrics),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    IconButton(
                        onClick = {
                            orderedBookIds = orderedBookIds.toMutableList().also { books ->
                                books.add(index - 1, books.removeAt(index))
                            }
                        },
                        enabled = index > 0 && !busy,
                    ) {
                        Icon(Icons.Default.KeyboardArrowUp, contentDescription = "Move up", tint = colors.secondaryText)
                    }
                    IconButton(
                        onClick = {
                            orderedBookIds = orderedBookIds.toMutableList().also { books ->
                                books.add(index + 1, books.removeAt(index))
                            }
                        },
                        enabled = index < orderedBookIds.lastIndex && !busy,
                    ) {
                        Icon(Icons.Default.KeyboardArrowDown, contentDescription = "Move down", tint = colors.secondaryText)
                    }
                    IconButton(
                        onClick = { orderedBookIds = orderedBookIds.filterNot { it == bookId } },
                        enabled = !busy,
                    ) {
                        Icon(Icons.Default.RemoveCircle, contentDescription = "Remove", tint = StorytellerRed)
                    }
                }
            }
        }
    }

    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = "Add Books")
        OutlinedTextField(
            value = search,
            onValueChange = { search = it },
            label = { Text("Search Storyteller books") },
            singleLine = true,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
        )
        when {
            matchingBooks.isEmpty() -> Text(
                if (search.isBlank()) "Every available book is already pinned." else "No available books match this search.",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
            )
            else -> {
                if (matchingBooks.size > visibleBooks.size) {
                    Text(
                        "Showing ${visibleBooks.size} of ${matchingBooks.size}. Refine the search to see more.",
                        color = colors.tertiaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                        modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.XS.scaled(metrics)),
                    )
                }
                visibleBooks.forEach { book ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                storytellerBookLabel(book),
                                color = colors.primaryText,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            book.authors?.firstOrNull()?.name?.takeIf { it.isNotBlank() }?.let { author ->
                                Text(
                                    author,
                                    color = colors.tertiaryText,
                                    fontSize = DS.FontSize.Caption.scaled(metrics),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        TextButton(
                            onClick = { orderedBookIds = orderedBookIds + book.uuid },
                            enabled = !busy,
                        ) {
                            Icon(Icons.Default.Add, contentDescription = null, tint = StorytellerTint)
                            Text("Add", color = StorytellerTint)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AlignmentQualityCard(state: StorytellerHubState) {
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = "Alignment Quality")
        val facets = state.facets
        when {
            facets == null && state.alignmentError != null -> PermissionNotice(
                error = state.alignmentError,
                hint = "Alignment tools require server support and the bookProcess permission on this Storyteller account.",
            )
            facets == null -> MetricRow("Grades", "--")
            else -> {
                facets.grades.entries
                    .sortedWith(
                        compareBy(
                            { ALIGNMENT_GRADE_ORDER.indexOf(it.key).takeIf { index -> index >= 0 } ?: Int.MAX_VALUE },
                            { it.key },
                        ),
                    )
                    .forEach { (grade, count) -> MetricRow("Grade $grade", count.toString()) }
                MetricRow("Graded books", facets.total.toString())
                MetricRow("Muted", facets.muted.toString())
            }
        }
    }
}

@Composable
private fun ProcessingCard(
    state: StorytellerHubState,
    onOpenReport: (String) -> Unit,
    onContinue: (StorytellerBookDto) -> Unit,
    onRestartSync: (StorytellerBookDto) -> Unit,
    onRestartTranscription: (StorytellerBookDto) -> Unit,
    onFullRestart: (StorytellerBookDto) -> Unit,
    onCancel: (StorytellerBookDto) -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)
    var search by remember { mutableStateOf("") }
    val matchingCandidates = remember(state.candidates, search) {
        val query = search.trim()
        if (query.isEmpty()) {
            state.candidates
        } else {
            state.candidates.filter { storytellerBookSearchText(it).contains(query, ignoreCase = true) }
        }
    }
    val visibleCandidates = matchingCandidates.take(MaxVisibleProcessBooks)
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(
            title = "Readaloud Processing",
            subtitle = if (state.processingError == null) "${state.candidates.size} books with ebook and audiobook" else null,
        )
        when {
            state.processingError != null && state.candidates.isEmpty() -> PermissionNotice(
                error = state.processingError,
                hint = "Processing controls need the bookProcess permission on this Storyteller account.",
            )
            state.candidates.isEmpty() -> Text(
                "No books have both an ebook and an audiobook to align.",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
            )
            else -> {
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    label = { Text("Search books") },
                    singleLine = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                )
                if (matchingCandidates.isEmpty()) {
                    Text(
                        "No matching books.",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                        modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                    )
                } else {
                    if (matchingCandidates.size > visibleCandidates.size) {
                        Text(
                            "Showing ${visibleCandidates.size} of ${matchingCandidates.size}. Refine the search to see more.",
                            color = colors.tertiaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                            modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.XS.scaled(metrics)),
                        )
                    }
                    visibleCandidates.forEachIndexed { index, book ->
                        ProcessRow(
                            book = book,
                            busy = state.busyBookId == book.uuid,
                            onOpenReport = { onOpenReport(book.uuid) },
                            onContinue = { onContinue(book) },
                            onRestartSync = { onRestartSync(book) },
                            onRestartTranscription = { onRestartTranscription(book) },
                            onFullRestart = { onFullRestart(book) },
                            onCancel = { onCancel(book) },
                        )
                        if (index < visibleCandidates.lastIndex) HorizontalDivider(color = dividerColor)
                    }
                }
            }
        }
    }
}

@Composable
private fun ProcessRow(
    book: StorytellerBookDto,
    busy: Boolean,
    onOpenReport: () -> Unit,
    onContinue: () -> Unit,
    onRestartSync: () -> Unit,
    onRestartTranscription: () -> Unit,
    onFullRestart: () -> Unit,
    onCancel: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val active = storytellerProcessingActive(book.readaloud)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    storytellerBookLabel(book),
                    color = colors.primaryText,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    readaloudStatusLine(book),
                    color = if (active) StorytellerTint else colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (busy) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = StorytellerTint)
            }
        }
        if (active) {
            book.readaloud?.stageProgress?.let { progress ->
                LinearProgressIndicator(
                    progress = { progress.toFloat().coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth(),
                    color = StorytellerTint,
                    trackColor = colors.separator.copy(alpha = 0.35f),
                )
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
        ) {
            ActionChip("Report", Icons.AutoMirrored.Filled.MenuBook, StorytellerTint, enabled = !busy, onClick = onOpenReport, modifier = Modifier.weight(1f))
            if (active) {
                ActionChip("Cancel", Icons.Default.Cancel, StorytellerRed, enabled = !busy, onClick = onCancel, modifier = Modifier.weight(1f))
            } else {
                ActionChip("Continue", Icons.Default.PlayArrow, StorytellerTint, enabled = !busy, onClick = onContinue, modifier = Modifier.weight(1f))
            }
        }
        if (!active) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
            ) {
                ActionChip("Re-sync", Icons.Default.RestartAlt, StorytellerTint, enabled = !busy, onClick = onRestartSync, modifier = Modifier.weight(1f))
                ActionChip("Re-transcribe", Icons.Default.RestartAlt, StorytellerTint, enabled = !busy, onClick = onRestartTranscription, modifier = Modifier.weight(1f))
                ActionChip("Full restart", Icons.Default.RestartAlt, StorytellerRed, enabled = !busy, onClick = onFullRestart, modifier = Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun ReportContent(report: StorytellerAlignmentReportDto) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)

    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(DS.Spacing.LG.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.XS.scaled(metrics)),
        ) {
            Text(
                report.bookTitle?.takeIf { it.isNotBlank() } ?: report.bookUuid,
                color = colors.primaryText,
                style = hearthDisplay(18.sp),
            )
            Text(
                buildString {
                    append("Grade ${report.summary.grade.ifBlank { "--" }}")
                    report.summary.score?.let { append(" · score ${"%.1f".format(it)}") }
                },
                color = StorytellerTint,
                fontWeight = FontWeight.SemiBold,
            )
            report.createdAt?.takeIf { it.isNotBlank() }?.let {
                Text(it, color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
            }
        }
    }

    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = "Summary")
        MetricRow("Chapters", report.summary.chapters.toString())
        MetricRow("Significant chapters", report.significantChapters.toString())
        MetricRow("Aligned sentences", "${report.alignedSentences} / ${report.totalSentences}")
        MetricRow("Missing sentences", report.summary.missingSentences.toString())
        MetricRow("Aligned audio", "${clockDuration(report.alignedAudioDuration)} / ${clockDuration(report.totalAudioDuration)}")
        MetricRow("Muted chapters", report.summary.mutedChapters.toString())
        MetricRow("Failed chapters", report.summary.failedChapters.toString())
        MetricRow("Unaligned audio files", report.summary.unalignedAudio.toString())
    }

    if (report.chapters.isNotEmpty()) {
        SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
            SettingsSectionHeader(title = "Chapters")
            report.chapters.forEachIndexed { index, chapter ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            chapter.title?.takeIf { it.isNotBlank() } ?: chapter.label,
                            color = if (chapter.flagged == true) StorytellerRed else colors.primaryText,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            "${chapter.alignedSentenceCount} / ${chapter.chapterSentenceCount}",
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                        )
                    }
                    val details = buildList {
                        chapter.coverage?.let { add("coverage ${(it * 100).roundToInt()}%") }
                        add("delta ${"%.1f".format(chapter.delta)} (${"%.1f".format(chapter.deltaPct * 100)}%)")
                        if (chapter.markedOk == true) add("marked OK")
                        if (chapter.excludedFromScore == true) add("excluded from score")
                    }
                    Text(
                        details.joinToString(" · "),
                        color = colors.tertiaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                    chapter.flags.forEach { flag ->
                        Text(
                            flag.label,
                            color = if (flag.tone.equals("poor", true)) StorytellerRed else StorytellerTint,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                        )
                    }
                }
                if (index < report.chapters.lastIndex) HorizontalDivider(color = dividerColor)
            }
        }
    }

    if (report.unalignedChapters.isNotEmpty()) {
        SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
            SettingsSectionHeader(title = "Unaligned Chapters")
            report.unalignedChapters.forEachIndexed { index, chapter ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            chapter.label,
                            color = colors.primaryText,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (chapter.intended == true) {
                            Text("Intended", color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                        }
                    }
                    Text(chapter.reason, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                    chapter.preview?.takeIf { it.isNotBlank() }?.let {
                        Text(it, color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics), maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                }
                if (index < report.unalignedChapters.lastIndex) HorizontalDivider(color = dividerColor)
            }
        }
    }

    if (report.unalignedAudioFiles.isNotEmpty()) {
        SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
            SettingsSectionHeader(title = "Unaligned Audio")
            report.unalignedAudioFiles.forEachIndexed { index, file ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            file.title?.takeIf { it.isNotBlank() } ?: file.filepath.substringAfterLast('/'),
                            color = colors.primaryText,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            listOfNotNull(
                                file.duration?.let(::clockDuration),
                                "Excluded".takeIf { file.excluded == true },
                            ).joinToString(" · "),
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                        )
                    }
                    file.transcription?.takeIf { it.isNotBlank() }?.let {
                        Text(it, color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics), maxLines = 3, overflow = TextOverflow.Ellipsis)
                    }
                }
                if (index < report.unalignedAudioFiles.lastIndex) HorizontalDivider(color = dividerColor)
            }
        }
    }
}

@Composable
private fun ShelfEditDialog(
    title: String,
    confirmLabel: String,
    initialName: String = "",
    withDescription: Boolean = false,
    onDismiss: () -> Unit,
    onConfirm: (String, String?) -> Unit,
) {
    val colors = EnveTheme.colors
    var name by remember { mutableStateOf(initialName) }
    var description by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM)) {
                OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                if (withDescription) {
                    OutlinedTextField(value = description, onValueChange = { description = it }, label = { Text("Description") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(name, description.takeIf { it.isNotBlank() }) },
                enabled = name.isNotBlank(),
            ) { Text(confirmLabel) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        containerColor = colors.cardBackground,
    )
}

@Composable
private fun ActionChip(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: Color,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        color = Color.Transparent,
        contentColor = tint,
        shape = RoundedCornerShape(999.dp),
        border = BorderStroke(1.dp, tint.copy(alpha = if (enabled) 1f else 0.4f)),
        enabled = enabled,
        modifier = modifier,
        onClick = onClick,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
            Text(label, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun MetricRow(label: String, value: String) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = colors.primaryText, modifier = Modifier.weight(1f))
        Text(value, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
    }
}

@Composable
private fun PermissionNotice(error: String, hint: String) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(hint, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
        Text(error, color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics), maxLines = 3, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun NoticeRowCard(text: String, actionLabel: String? = null, onAction: (() -> Unit)? = null) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(DS.Spacing.LG.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text,
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
                modifier = Modifier.weight(1f),
            )
            if (actionLabel != null && onAction != null) {
                TextButton(onClick = onAction) { Text(actionLabel, color = StorytellerTint) }
            }
        }
    }
}

@Composable
private fun LoadingRowCard(text: String) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(DS.Spacing.LG.scaled(metrics)),
            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(color = StorytellerTint, modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
            Text(text, color = colors.secondaryText)
        }
    }
}

private fun storytellerBookLabel(book: StorytellerBookDto): String =
    book.title.takeIf { it.isNotBlank() } ?: book.uuid

private fun storytellerBookSearchText(book: StorytellerBookDto): String = buildString {
    append(book.title)
    book.subtitle?.let { append(' ').append(it) }
    book.authors.orEmpty().forEach { append(' ').append(it.name) }
}

private fun restartConfirmationTitle(restart: StorytellerProcessRestart): String = when (restart) {
    StorytellerProcessRestart.SYNC -> "Restart synchronization?"
    StorytellerProcessRestart.TRANSCRIPTION -> "Restart transcription?"
    StorytellerProcessRestart.FULL -> "Restart from scratch?"
}

private fun restartConfirmationMessage(
    book: StorytellerBookDto,
    restart: StorytellerProcessRestart,
): String = when (restart) {
    StorytellerProcessRestart.SYNC ->
        "Storyteller will keep existing files and synchronize '${storytellerBookLabel(book)}' again."
    StorytellerProcessRestart.TRANSCRIPTION ->
        "Storyteller will discard its transcriptions for '${storytellerBookLabel(book)}' and rebuild them."
    StorytellerProcessRestart.FULL ->
        "Storyteller will delete all cached alignment work for '${storytellerBookLabel(book)}' and start over."
}

private fun readaloudStatusLine(book: StorytellerBookDto): String {
    val readaloud = book.readaloud ?: return "Not processed"
    val parts = mutableListOf<String>()
    parts += readaloud.status?.takeIf { it.isNotBlank() }?.lowercase()?.replaceFirstChar { it.uppercase() } ?: "Not processed"
    if (storytellerProcessingActive(readaloud)) {
        readaloud.currentStage?.takeIf { it.isNotBlank() }?.let { stage ->
            val progress = readaloud.stageProgress?.let { " ${(it * 100).roundToInt()}%" }.orEmpty()
            parts += stage.lowercase().replace('_', ' ') + progress
        }
        readaloud.queuePosition?.let { parts += "queue #$it" }
    }
    if (readaloud.restartPending == true) parts += "restart pending"
    return parts.joinToString(" · ")
}

private fun clockDuration(seconds: Double): String {
    val safe = seconds.roundToInt().coerceAtLeast(0)
    val hours = safe / 3600
    val minutes = (safe % 3600) / 60
    val remainder = safe % 60
    return if (hours > 0) "%d:%02d:%02d".format(hours, minutes, remainder) else "%d:%02d".format(minutes, remainder)
}
