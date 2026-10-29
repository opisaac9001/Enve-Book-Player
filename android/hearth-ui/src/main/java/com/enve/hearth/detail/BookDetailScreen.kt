package com.enve.hearth.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.enve.hearth.shell.profileViewModel
import com.enve.hearth.listeningposition.ListeningPositionShareSheet
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ReaderAnnotation
import com.enve.engine.library.AudiobookshelfHistoryCandidate
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthDismissStyle
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.hearthDismissGesture
import com.enve.hearth.design.rememberHearthDismissState
import com.enve.engine.library.SavedBookList
import kotlin.math.roundToInt

@Composable
fun BookDetailScreen(
    initial: Book,
    onBack: () -> Unit,
    onListen: (Book) -> Unit,
    onListenAt: (Book, Long) -> Unit = { book, _ -> onListen(book) },
    onRead: (Book) -> Unit,
    onOpenBook: (Book) -> Unit,
    onAskLibrarian: (Book) -> Unit = {},
    onOpenAnnotation: (Book, ReaderAnnotation) -> Unit = { _, _ -> },
) {
    val vm: HearthDetailViewModel = profileViewModel()
    LaunchedEffect(initial.uniqueKey) { vm.load(initial) }
    val book by vm.book.collectAsStateWithLifecycle()
    val linkedAudiobook by vm.linkedAudiobook.collectAsStateWithLifecycle()
    val linkedEbook by vm.linkedEbook.collectAsStateWithLifecycle()
    val inSeries by vm.inSeries.collectAsStateWithLifecycle()
    val chapters by vm.chapters.collectAsStateWithLifecycle()
    val chaptersLoading by vm.chaptersLoading.collectAsStateWithLifecycle()
    val chaptersFailed by vm.chaptersFailed.collectAsStateWithLifecycle()
    val notice by vm.notice.collectAsStateWithLifecycle()
    val metadataEditSupported by vm.metadataEditSupported.collectAsStateWithLifecycle()
    val personalRatingSupported by vm.personalRatingSupported.collectAsStateWithLifecycle()
    val personalRatingUpdating by vm.personalRatingUpdating.collectAsStateWithLifecycle()
    val metadataQuery by vm.metadataQuery.collectAsStateWithLifecycle()
    val metadataMatches by vm.metadataMatches.collectAsStateWithLifecycle()
    val metadataSearching by vm.metadataSearching.collectAsStateWithLifecycle()
    val linkCandidateQuery by vm.linkCandidateQuery.collectAsStateWithLifecycle()
    val linkCandidates by vm.linkCandidates.collectAsStateWithLifecycle()
    val linkCandidatesLoading by vm.linkCandidatesLoading.collectAsStateWithLifecycle()
    val historyTarget by vm.historyTarget.collectAsStateWithLifecycle()
    val historyQuery by vm.historyQuery.collectAsStateWithLifecycle()
    val historyCandidates by vm.historyCandidates.collectAsStateWithLifecycle()
    val historyCandidatesLoading by vm.historyCandidatesLoading.collectAsStateWithLifecycle()
    val downloadState by vm.downloadState.collectAsStateWithLifecycle()
    val counterpartDownloadState by vm.counterpartDownloadState.collectAsStateWithLifecycle()
    val annotations by vm.annotations.collectAsStateWithLifecycle()
    val knownTags by vm.knownTags.collectAsStateWithLifecycle()
    val bookOrbitCollections by vm.bookOrbitCollections.collectAsStateWithLifecycle()
    val bookOrbitRelated by vm.bookOrbitRelated.collectAsStateWithLifecycle()
    val saved by vm.saved.collectAsStateWithLifecycle()
    val savedSyncErrors by vm.savedSyncErrors.collectAsStateWithLifecycle()
    val relatedBooks by vm.relatedBooks.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    val b = book ?: initial
    val favorite = remember(saved, b) { vm.isSaved(b, SavedBookList.FAVORITES) }
    val forLater = remember(saved, b) { vm.isSaved(b, SavedBookList.LATER) }
    var sharePositionShown by remember { mutableStateOf(false) }
    if (sharePositionShown) ListeningPositionShareSheet(b) { sharePositionShown = false }
    var showEditMetadata by remember { mutableStateOf(false) }
    var showMetadataMatches by remember { mutableStateOf(false) }
    var showLinkDialog by remember { mutableStateOf(false) }
    var showHistoryDialog by remember { mutableStateOf(false) }
    var selectedHistoryTarget by remember { mutableStateOf<AudiobookshelfHistoryCandidate?>(null) }
    var showDeleteConfirm by remember { mutableStateOf(false) }
    var showBookOrbitCollections by remember { mutableStateOf(false) }
    var annotationFilter by remember(initial.id) { mutableStateOf(AnnotationFilter.ALL) }
    var annotationQuery by remember(initial.id) { mutableStateOf("") }
    var editingAnnotation by remember { mutableStateOf<ReaderAnnotation?>(null) }
    val ambientColor = rememberDetailAmbientColor(b.coverUrl, palette.ember)
    val dismissState = rememberHearthDismissState(HearthDismissStyle.Page, onBack)

    Box(Modifier.fillMaxSize().hearthDismissGesture(dismissState).background(palette.bg)) {
        DetailAmbientWash(ambientColor)
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = LocalMantelInset.current + Hearth.Spacing.L),
        ) {
            item { DetailHeader(b, ambientColor, onBack) }
            item { DetailActions(b, chapters, linkedAudiobook, linkedEbook, onListen, onRead) }
            item {
                DetailSecondaryActions(
                    b = b,
                    vm = vm,
                    downloadState = downloadState,
                    counterpart = if (b.source == BookSource.GRIMMORY) {
                        if (b.mediaType == AppMediaType.EBOOK) linkedAudiobook else linkedEbook
                    } else null,
                    counterpartDownloadState = counterpartDownloadState,
                    metadataEditSupported = metadataEditSupported,
                    onHidden = onBack,
                    onAskLibrarian = onAskLibrarian,
                    onEditMetadata = { showEditMetadata = true },
                    onFindBetterMatch = {
                        showMetadataMatches = true
                        vm.startMetadataMatch()
                    },
                    onAudiobookshelfHistory = {
                        showHistoryDialog = true
                        vm.prepareAudiobookshelfHistory()
                    },
                    onLinkEditions = {
                        if (supportsEditionLinking(b)) {
                            showLinkDialog = true
                        }
                        vm.prepareEditionLinking()
                    },
                    canManageBookOrbitCollections = bookOrbitCollections.isNotEmpty(),
                    onBookOrbitCollections = { showBookOrbitCollections = true },
                    isFavorite = favorite,
                    isForLater = forLater,
                    onToggleFavorite = { vm.toggleSaved(b, SavedBookList.FAVORITES) },
                    onToggleForLater = { vm.toggleSaved(b, SavedBookList.LATER) },
                    onDelete = { showDeleteConfirm = true },
                    onSharePosition = { sharePositionShown = true },
                )
            }
            (savedSyncErrors[b.uniqueKey] ?: b.connectionId?.let { savedSyncErrors[it] })?.let { message ->
                item {
                    Text(
                        "Saved on this device, but $message",
                        style = HearthText.Caption,
                        color = palette.statusError,
                        modifier = Modifier.padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.S),
                    )
                }
            }
            if (personalRatingSupported) {
                item {
                    PersonalRatingSection(
                        rating = b.personalRating?.roundToInt(),
                        sourceName = b.source.displayName,
                        updating = personalRatingUpdating,
                        onRate = vm::setPersonalRating,
                    )
                }
            }
            b.description?.let { stripHtml(it) }?.takeIf { it.isNotBlank() }?.let { item { DetailDescription(it) } }
            item { AboutGrid(b) }
            if (b.mediaType == AppMediaType.AUDIOBOOK || b.hasAudio) {
                item {
                    ChaptersSection(
                        b = b,
                        chapters = chapters,
                        loading = chaptersLoading,
                        failed = chaptersFailed,
                        onRetry = vm::retryChapters,
                        onListenAt = onListenAt,
                        canSeparate = vm::canSeparateChapter,
                        onSeparate = { chapter -> vm.separateChapter(chapter, onBack) },
                    )
                }
            }
            item {
                AnnotationsSection(
                    annotations = annotations,
                    filter = annotationFilter,
                    query = annotationQuery,
                    tagsFor = vm::tagsFor,
                    onFilterChange = { annotationFilter = it },
                    onQueryChange = { annotationQuery = it },
                    onJump = { onOpenAnnotation(b, it) },
                    onEdit = { editingAnnotation = it },
                )
            }
            if (inSeries.isNotEmpty()) {
                item { BookShelfRow("In this series", inSeries, onOpenBook) }
            }
            if (relatedBooks.isNotEmpty()) {
                item { BookShelfRow(relatedShelfTitle(b.source), relatedBooks, onOpenBook) }
            }
            bookOrbitRelated?.let { related ->
                val openFromBookOrbit: (Int) -> Unit = { id -> vm.openBookOrbitBook(id, onOpenBook) }
                if (related.seriesBooks.isNotEmpty()) {
                    item { RelatedShelf("More in this series", related.seriesBooks, openFromBookOrbit) }
                }
                if (related.authorBooks.isNotEmpty()) {
                    item { RelatedShelf("More by this author", related.authorBooks, openFromBookOrbit) }
                }
                if (related.recommendations.isNotEmpty()) {
                    item { RelatedShelf("BookOrbit recommends", related.recommendations, openFromBookOrbit) }
                }
            }
        }
        notice?.let { msg ->
            LaunchedEffect(msg) {
                kotlinx.coroutines.delay(4000)
                vm.dismissNotice()
            }
            Box(
                Modifier.align(Alignment.BottomCenter).padding(bottom = LocalMantelInset.current)
                    .padding(horizontal = Hearth.Spacing.XL)
                    .clip(RoundedCornerShape(999.dp))
                    .background(palette.bgElevated)
                    .border(1.dp, palette.hairline, RoundedCornerShape(999.dp))
                    .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.S),
            ) {
                Text(msg, style = HearthText.Caption, color = palette.text)
            }
        }
        if (showEditMetadata) {
            MetadataEditDialog(
                book = b,
                onDismiss = { showEditMetadata = false },
                onSave = { edit ->
                    showEditMetadata = false
                    vm.saveMetadata(edit)
                },
            )
        }
        if (showMetadataMatches) {
            MetadataMatchDialog(
                query = metadataQuery,
                matches = metadataMatches,
                searching = metadataSearching,
                onQueryChange = vm::searchMetadata,
                onApply = { match ->
                    showMetadataMatches = false
                    vm.applyMetadataMatch(match)
                },
                onDismiss = { showMetadataMatches = false },
            )
        }
        if (showHistoryDialog) {
            AudiobookshelfHistoryDialog(
                currentTarget = historyTarget,
                query = historyQuery,
                candidates = historyCandidates,
                loading = historyCandidatesLoading,
                onQueryChange = vm::updateAudiobookshelfHistoryQuery,
                onLink = { target ->
                    showHistoryDialog = false
                    selectedHistoryTarget = target
                },
                onUnlink = {
                    showHistoryDialog = false
                    vm.unlinkAudiobookshelfHistory()
                },
                onDismiss = { showHistoryDialog = false },
            )
        }
        selectedHistoryTarget?.let { selected ->
            AlertDialog(
                onDismissRequest = { selectedHistoryTarget = null },
                title = { Text("Confirm listening history") },
                text = { Text("Share local Grimmory listening for this book with Audiobookshelf account ${selected.accountName} and item ${selected.book.title}? Older sessions on this connection may belong to a previous account.") },
                confirmButton = {
                    TextButton(onClick = {
                        vm.linkAudiobookshelfHistory(selected.book, includePast = false)
                        selectedHistoryTarget = null
                    }) { Text("Start now") }
                },
                dismissButton = {
                    Row {
                        TextButton(onClick = {
                            vm.linkAudiobookshelfHistory(selected.book, includePast = true)
                            selectedHistoryTarget = null
                        }) { Text("Include past sessions") }
                        TextButton(onClick = { selectedHistoryTarget = null }) { Text("Cancel") }
                    }
                },
            )
        }
        if (showLinkDialog) {
            EditionLinkDialog(
                book = b,
                currentLinked = when (b.mediaType) {
                    AppMediaType.EBOOK -> linkedAudiobook
                    AppMediaType.AUDIOBOOK -> linkedEbook
                    else -> null
                },
                query = linkCandidateQuery,
                candidates = linkCandidates,
                loading = linkCandidatesLoading,
                onQueryChange = vm::updateLinkCandidateQuery,
                onLink = { candidate ->
                    showLinkDialog = false
                    vm.linkEditionTo(candidate)
                },
                onUnlink = {
                    showLinkDialog = false
                    vm.unlinkEdition()
                },
                onDismiss = { showLinkDialog = false },
            )
        }
        if (showDeleteConfirm) {
            AlertDialog(
                onDismissRequest = { showDeleteConfirm = false },
                title = { Text("Delete from library") },
                text = { Text("This can permanently remove local files from Enve's library. Server books will not be deleted.") },
                confirmButton = {
                    TextButton(onClick = {
                        showDeleteConfirm = false
                        vm.deleteFromLibrary(onBack)
                    }) { Text("Delete") }
                },
                dismissButton = {
                    TextButton(onClick = { showDeleteConfirm = false }) { Text("Cancel") }
                },
            )
        }
        if (showBookOrbitCollections) {
            BookOrbitMembershipDialog(
                book = b,
                memberships = bookOrbitCollections,
                onDismiss = { showBookOrbitCollections = false },
                onChange = vm::setBookOrbitCollectionMembership,
            )
        }
        editingAnnotation?.let { annotation ->
            AnnotationEditDialog(
                annotation = annotation,
                currentTags = vm.tagsFor(annotation),
                knownTags = knownTags,
                onDismiss = { editingAnnotation = null },
                onJump = {
                    editingAnnotation = null
                    onOpenAnnotation(b, annotation)
                },
                onSave = { style, colorHex, note, tags ->
                    editingAnnotation = null
                    vm.saveAnnotation(annotation, style, colorHex, note, tags)
                },
                onDelete = {
                    editingAnnotation = null
                    vm.deleteAnnotation(annotation)
                },
            )
        }
    }
}
