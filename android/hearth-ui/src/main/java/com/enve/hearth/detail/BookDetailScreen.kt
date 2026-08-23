package com.enve.hearth.detail

import android.content.ClipData
import android.graphics.Bitmap
import android.graphics.Color as AndroidColor
import android.text.format.DateUtils
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.core.graphics.drawable.toBitmap
import coil.imageLoader
import coil.request.ImageRequest
import coil.request.SuccessResult
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.ReaderAnnotation
import com.enve.engine.library.LibraryDownloadState
import com.enve.engine.library.LibraryDownloadStatus
import com.enve.engine.library.LibraryLinkCandidate
import com.enve.engine.library.LibraryMetadataEdit
import com.enve.engine.library.LibraryMetadataMatch
import com.enve.engine.library.BookOrbitCollectionMembership
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthFormat
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalHearthImageLoader
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.Ribbon
import com.enve.engine.bookorbit.BookOrbitRelatedBook
import com.enve.hearth.design.ShelfHeader
import com.enve.hearth.design.hearthDisplay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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
    val vm: HearthDetailViewModel = hiltViewModel()
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
    val downloadState by vm.downloadState.collectAsStateWithLifecycle()
    val annotations by vm.annotations.collectAsStateWithLifecycle()
    val knownTags by vm.knownTags.collectAsStateWithLifecycle()
    val bookOrbitCollections by vm.bookOrbitCollections.collectAsStateWithLifecycle()
    val bookOrbitRelated by vm.bookOrbitRelated.collectAsStateWithLifecycle()
    val relatedBooks by vm.relatedBooks.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    val b = book ?: initial
    var showEditMetadata by remember { mutableStateOf(false) }
    var showMetadataMatches by remember { mutableStateOf(false) }
    var showLinkDialog by remember { mutableStateOf(false) }
    var showDeleteConfirm by remember { mutableStateOf(false) }
    var showBookOrbitCollections by remember { mutableStateOf(false) }
    var annotationFilter by remember(initial.id) { mutableStateOf(AnnotationFilter.ALL) }
    var annotationQuery by remember(initial.id) { mutableStateOf("") }
    var editingAnnotation by remember { mutableStateOf<ReaderAnnotation?>(null) }
    val ambientColor = rememberDetailAmbientColor(b.coverUrl, palette.ember)

    Box(Modifier.fillMaxSize().background(palette.bg)) {
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
                    metadataEditSupported = metadataEditSupported,
                    onHidden = onBack,
                    onAskLibrarian = onAskLibrarian,
                    onEditMetadata = { showEditMetadata = true },
                    onFindBetterMatch = {
                        showMetadataMatches = true
                        vm.startMetadataMatch()
                    },
                    onLinkEditions = {
                        if (supportsEditionLinking(b)) {
                            showLinkDialog = true
                        }
                        vm.prepareEditionLinking()
                    },
                    canManageBookOrbitCollections = bookOrbitCollections.isNotEmpty(),
                    onBookOrbitCollections = { showBookOrbitCollections = true },
                    onDelete = { showDeleteConfirm = true },
                )
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

@Composable
private fun PersonalRatingSection(
    rating: Int?,
    sourceName: String,
    updating: Boolean,
    onRate: (Int) -> Unit,
) {
    val palette = Hearth.palette
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Hearth.Spacing.XL)
            .padding(top = Hearth.Spacing.L)
            .clip(RoundedCornerShape(Hearth.Radius.Card))
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card))
            .padding(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Overline("Your rating")
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
        ) {
            (1..5).forEach { value ->
                Icon(
                    imageVector = if (value <= (rating ?: 0)) Icons.Filled.Star else Icons.Outlined.Star,
                    contentDescription = "$value star${if (value == 1) "" else "s"}",
                    tint = if (value <= (rating ?: 0)) palette.ember else palette.textTertiary,
                    modifier = Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .clickable(enabled = !updating) { onRate(value) }
                        .padding(3.dp),
                )
            }
            if (updating) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                    color = palette.ember,
                )
            }
        }
        Text(
            if (rating == null) "Choose 1-5 stars. This saves to $sourceName."
            else "$rating of 5 · Saved with $sourceName",
            style = HearthText.Caption,
            color = palette.textSecondary,
        )
    }
}

@Composable
private fun rememberDetailAmbientColor(coverUrl: String?, fallback: Color): Color {
    val context = LocalContext.current
    val sharedLoader = LocalHearthImageLoader.current
    var color by remember(coverUrl, fallback) { mutableStateOf(fallback) }

    LaunchedEffect(coverUrl, fallback, sharedLoader) {
        val url = coverUrl?.takeIf { it.isNotBlank() }
        if (url == null) {
            color = fallback
            return@LaunchedEffect
        }

        val request = ImageRequest.Builder(context)
            .data(url)
            .allowHardware(false)
            .size(96, 144)
            .build()
        val result = runCatching { (sharedLoader ?: context.imageLoader).execute(request) }.getOrNull()
        val drawable = (result as? SuccessResult)?.drawable
        color = if (drawable == null) {
            fallback
        } else {
            withContext(Dispatchers.Default) {
                drawable.toBitmap(width = 72, height = 108, config = Bitmap.Config.ARGB_8888)
                    .coverAmbientColor()
            } ?: fallback
        }
    }

    return color
}

private fun Bitmap.coverAmbientColor(): Color? {
    var weightedRed = 0f
    var weightedGreen = 0f
    var weightedBlue = 0f
    var totalWeight = 0f
    val stepX = (width / 28).coerceAtLeast(1)
    val stepY = (height / 28).coerceAtLeast(1)

    for (y in stepY / 2 until height step stepY) {
        for (x in stepX / 2 until width step stepX) {
            val pixel = getPixel(x, y)
            if (AndroidColor.alpha(pixel) < 200) continue

            val red = AndroidColor.red(pixel)
            val green = AndroidColor.green(pixel)
            val blue = AndroidColor.blue(pixel)
            val max = maxOf(red, green, blue)
            val min = minOf(red, green, blue)
            val brightness = max / 255f
            val saturation = if (max == 0) 0f else (max - min) / max.toFloat()
            if (brightness < 0.08f || brightness > 0.95f || saturation < 0.06f) continue

            val weight = (0.18f + saturation) * brightness
            weightedRed += red * weight
            weightedGreen += green * weight
            weightedBlue += blue * weight
            totalWeight += weight
        }
    }

    if (totalWeight <= 0f) return null
    val red = (weightedRed / totalWeight).roundToInt().coerceIn(0, 255)
    val green = (weightedGreen / totalWeight).roundToInt().coerceIn(0, 255)
    val blue = (weightedBlue / totalWeight).roundToInt().coerceIn(0, 255)
    return tunedAmbientColor(red, green, blue)
}

private fun tunedAmbientColor(red: Int, green: Int, blue: Int): Color {
    val hsv = FloatArray(3)
    AndroidColor.RGBToHSV(red, green, blue, hsv)
    hsv[1] = hsv[1].coerceIn(0.24f, 0.72f)
    hsv[2] = (hsv[2] * 0.62f).coerceIn(0.22f, 0.46f)
    return Color(AndroidColor.HSVToColor(hsv))
}

@Composable
private fun DetailAmbientWash(color: Color) {
    if (Hearth.eink.suppressGradients) return

    Box(
        Modifier.fillMaxWidth()
            .height(640.dp)
            .background(
                Brush.verticalGradient(
                    colorStops = arrayOf(
                        0.00f to color.copy(alpha = 0.30f),
                        0.36f to color.copy(alpha = 0.20f),
                        0.68f to color.copy(alpha = 0.08f),
                        1.00f to Color.Transparent,
                    ),
                ),
            ),
    )
}

@Composable
private fun DetailSecondaryActions(
    b: Book,
    vm: HearthDetailViewModel,
    downloadState: LibraryDownloadState,
    metadataEditSupported: Boolean,
    onHidden: () -> Unit,
    onAskLibrarian: (Book) -> Unit,
    onEditMetadata: () -> Unit,
    onFindBetterMatch: () -> Unit,
    onLinkEditions: () -> Unit,
    canManageBookOrbitCollections: Boolean,
    onBookOrbitCollections: () -> Unit,
    onDelete: () -> Unit,
) {
    val palette = Hearth.palette
    val clipboard = LocalClipboard.current
    val coroutineScope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var confirmRemoveDownload by remember(b.uniqueKey) { mutableStateOf(false) }
    var confirmResetProgress by remember(b.uniqueKey) { mutableStateOf(false) }
    var confirmHide by remember(b.uniqueKey) { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.M),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DownloadStatusPill(
            book = b,
            state = downloadState,
            onClick = {
                if (b.isDownloaded || downloadState.status == LibraryDownloadStatus.COMPLETED) confirmRemoveDownload = true
                else vm.toggleDownload()
            },
        )
        FinishedStatusPill(
            finished = b.isFinished,
            onClick = vm::toggleFinished,
        )
        Box {
            Box(
                Modifier.size(52.dp)
                    .clip(CircleShape)
                    .background(palette.bgElevated)
                    .border(1.dp, palette.hairline, CircleShape)
                    .clickable { menu = true },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Outlined.MoreHoriz,
                    contentDescription = "More",
                    tint = palette.textSecondary,
                    modifier = Modifier.size(22.dp),
                )
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Copy title") }, onClick = {
                    menu = false
                    coroutineScope.launch {
                        clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Book title", b.title)))
                    }
                })
                DropdownMenuItem(text = { Text("Ask Librarian") }, onClick = {
                    menu = false
                    onAskLibrarian(b)
                })
                DropdownMenuItem(text = { Text("Edit metadata") }, onClick = {
                    menu = false
                    if (metadataEditSupported) onEditMetadata() else vm.metadataEditUnavailable()
                })
                DropdownMenuItem(text = { Text("Find a better match") }, onClick = {
                    menu = false
                    onFindBetterMatch()
                })
                DropdownMenuItem(text = { Text("Link ebook/audiobook") }, onClick = {
                    menu = false
                    onLinkEditions()
                })
                DropdownMenuItem(text = { Text("Fetch chapters") }, onClick = {
                    menu = false
                    vm.fetchChaptersFromMenu()
                })
                DropdownMenuItem(text = { Text("Reset progress") }, onClick = { menu = false; confirmResetProgress = true })
                if (canManageBookOrbitCollections) {
                    DropdownMenuItem(text = { Text("BookOrbit collections") }, onClick = {
                        menu = false
                        onBookOrbitCollections()
                    })
                }
                DropdownMenuItem(text = { Text("Hide from library") }, onClick = { menu = false; confirmHide = true })
                DropdownMenuItem(text = { Text("Delete from library") }, onClick = { menu = false; onDelete() })
            }
        }
    }
    if (confirmRemoveDownload) {
        AlertDialog(
            onDismissRequest = { confirmRemoveDownload = false },
            title = { Text("Remove download?") },
            text = { Text("This removes the downloaded files for \"${b.title}\" from this device.") },
            confirmButton = {
                TextButton(onClick = { confirmRemoveDownload = false; vm.removeDownload() }) {
                    Text("Remove", color = palette.statusError)
                }
            },
            dismissButton = { TextButton(onClick = { confirmRemoveDownload = false }) { Text("Cancel") } },
        )
    }
    if (confirmResetProgress) {
        AlertDialog(
            onDismissRequest = { confirmResetProgress = false },
            title = { Text("Reset reading progress?") },
            text = { Text("This resets saved progress for \"${b.title}\" locally and on its connected server.") },
            confirmButton = {
                TextButton(onClick = { confirmResetProgress = false; vm.resetProgress() }) {
                    Text("Reset", color = palette.statusError)
                }
            },
            dismissButton = { TextButton(onClick = { confirmResetProgress = false }) { Text("Cancel") } },
        )
    }
    if (confirmHide) {
        AlertDialog(
            onDismissRequest = { confirmHide = false },
            title = { Text("Hide from library?") },
            text = { Text("This hides \"${b.title}\" from Enve's library.") },
            confirmButton = {
                TextButton(onClick = { confirmHide = false; vm.hide(); onHidden() }) {
                    Text("Hide", color = palette.statusError)
                }
            },
            dismissButton = { TextButton(onClick = { confirmHide = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun BookOrbitMembershipDialog(
    book: Book,
    memberships: List<BookOrbitCollectionMembership>,
    onDismiss: () -> Unit,
    onChange: (String, Boolean) -> Unit,
) {
    var pendingRemoval by remember { mutableStateOf<BookOrbitCollectionMembership?>(null) }

    if (pendingRemoval == null) {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("BookOrbit collections") },
            text = {
                Column {
                    memberships.forEach { membership ->
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                if (membership.containsBook) pendingRemoval = membership
                                else onChange(membership.collection.key, true)
                            }.padding(vertical = Hearth.Spacing.M),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(membership.collection.name, modifier = Modifier.weight(1f))
                            Text(if (membership.containsBook) "✓" else "+", color = Hearth.palette.ember)
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        )
    }

    pendingRemoval?.let { membership ->
        AlertDialog(
            onDismissRequest = { pendingRemoval = null },
            title = { Text("Remove from collection?") },
            text = { Text("Remove \"${book.title}\" from \"${membership.collection.name}\" on BookOrbit?") },
            confirmButton = {
                TextButton(onClick = {
                    onChange(membership.collection.key, false)
                    pendingRemoval = null
                }) { Text("Remove", color = Hearth.palette.statusError) }
            },
            dismissButton = { TextButton(onClick = { pendingRemoval = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun DownloadStatusPill(
    book: Book,
    state: LibraryDownloadState,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(999.dp)
    val progress by animateFloatAsState(
        targetValue = state.progress.coerceIn(0f, 1f),
        animationSpec = tween(250),
        label = "detail_download_progress",
    )
    val label = downloadLabel(book, state, progress)
    Row(
        modifier
            .height(52.dp)
            .widthIn(min = 148.dp)
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 18.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DownloadGlyph(book = book, state = state, progress = progress)
        Spacer(Modifier.width(7.dp))
        Text(
            label,
            style = HearthText.Label.copy(fontWeight = FontWeight.Medium),
            color = palette.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun FinishedStatusPill(
    finished: Boolean,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(999.dp)
    Row(
        Modifier.height(52.dp)
            .widthIn(min = 118.dp)
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            if (finished) "✓" else "○",
            style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold),
            color = if (finished) palette.ember else palette.textSecondary,
        )
        Spacer(Modifier.width(7.dp))
        Text(
            if (finished) "Finished" else "Mark\nfinished",
            style = HearthText.Label.copy(fontWeight = FontWeight.Medium),
            color = palette.text,
            maxLines = 2,
            textAlign = TextAlign.Center,
            lineHeight = 16.sp,
        )
    }
}

@Composable
private fun DownloadGlyph(book: Book, state: LibraryDownloadState, progress: Float) {
    val palette = Hearth.palette
    when {
        book.isDownloaded || state.status == LibraryDownloadStatus.COMPLETED -> {
            Text("✓", style = HearthText.Label, color = palette.ember)
        }
        state.isActive -> {
            Canvas(Modifier.size(15.dp)) {
                val stroke = 2.5.dp.toPx()
                drawCircle(color = palette.hairline, style = Stroke(stroke))
                drawArc(
                    color = palette.ember,
                    startAngle = -90f,
                    sweepAngle = 360f * progress.coerceAtLeast(0.02f),
                    useCenter = false,
                    style = Stroke(width = stroke, cap = StrokeCap.Round),
                )
            }
        }
        state.status == LibraryDownloadStatus.FAILED || state.status == LibraryDownloadStatus.CANCELLED -> {
            Text("↻", style = HearthText.Label, color = palette.text)
        }
        else -> Text("↓", style = HearthText.Label, color = palette.text)
    }
}

private fun downloadLabel(book: Book, state: LibraryDownloadState, progress: Float): String =
    when {
        book.isDownloaded || state.status == LibraryDownloadStatus.COMPLETED -> "Downloaded"
        state.status == LibraryDownloadStatus.QUEUED -> "Queued"
        state.status == LibraryDownloadStatus.DOWNLOADING -> "${(progress * 100).roundToInt()}%"
        state.status == LibraryDownloadStatus.FAILED || state.status == LibraryDownloadStatus.CANCELLED -> "Try again"
        else -> "Download"
    }

private enum class AnnotationFilter(val label: String) {
    ALL("All"),
    BOOKMARKS("Bookmarks"),
    HIGHLIGHTS("Highlights"),
    NOTES("Notes"),
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AnnotationsSection(
    annotations: List<ReaderAnnotation>,
    filter: AnnotationFilter,
    query: String,
    tagsFor: (ReaderAnnotation) -> List<String>,
    onFilterChange: (AnnotationFilter) -> Unit,
    onQueryChange: (String) -> Unit,
    onJump: (ReaderAnnotation) -> Unit,
    onEdit: (ReaderAnnotation) -> Unit,
) {
    val palette = Hearth.palette
    val liveAnnotations = annotations.filter { it.deletedAt == null }
    val bookmarks = liveAnnotations.count { AnnotationKind.parse(it.kind) == AnnotationKind.BOOKMARK }
    val highlights = liveAnnotations.count { AnnotationKind.parse(it.kind) == AnnotationKind.HIGHLIGHT }
    val notes = liveAnnotations.count { AnnotationKind.parse(it.kind) == AnnotationKind.NOTE }
    val shown = liveAnnotations
        .filter { annotation ->
            when (filter) {
                AnnotationFilter.ALL -> true
                AnnotationFilter.BOOKMARKS -> AnnotationKind.parse(annotation.kind) == AnnotationKind.BOOKMARK
                AnnotationFilter.HIGHLIGHTS -> AnnotationKind.parse(annotation.kind) == AnnotationKind.HIGHLIGHT
                AnnotationFilter.NOTES -> AnnotationKind.parse(annotation.kind) == AnnotationKind.NOTE
            }
        }
        .filter { annotation ->
            val needle = query.trim()
            if (needle.isBlank()) true else {
                val haystack = listOf(
                    annotation.selectedText,
                    annotation.note,
                    annotation.chapterId.orEmpty(),
                    tagsFor(annotation).joinToString(" "),
                    annotationLocation(annotation),
                ).joinToString(" ").lowercase()
                haystack.contains(needle.lowercase())
            }
        }
        .sortedWith(compareByDescending<ReaderAnnotation> { it.updatedAt }.thenByDescending { it.createdAt })

    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.XL)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            ShelfHeader("Bookmarks & notes", modifier = Modifier.weight(1f))
            Text("${liveAnnotations.size}", style = HearthText.Caption, color = palette.textTertiary)
        }
        Spacer(Modifier.height(Hearth.Spacing.XS))
        Text(
            "$bookmarks bookmarks · $highlights highlights · $notes notes",
            style = HearthText.Caption,
            color = palette.textSecondary,
        )
        Spacer(Modifier.height(Hearth.Spacing.M))
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            AnnotationFilter.entries.forEach { f ->
                HearthChip(f.label, selected = filter == f, onClick = { onFilterChange(f) })
            }
        }
        Spacer(Modifier.height(Hearth.Spacing.M))
        OutlinedTextField(
            value = query,
            onValueChange = onQueryChange,
            label = { Text("Search marks") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(Hearth.Spacing.M))
        when {
            liveAnnotations.isEmpty() -> Text(
                "Bookmarks, highlights, and notes from the reader or player will appear here.",
                style = HearthText.Body,
                color = palette.textSecondary,
            )
            shown.isEmpty() -> Text(
                "No marks match this view.",
                style = HearthText.Body,
                color = palette.textSecondary,
            )
            else -> Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                shown.forEach { annotation ->
                    AnnotationRow(
                        annotation = annotation,
                        tags = tagsFor(annotation),
                        onJump = { onJump(annotation) },
                        onEdit = { onEdit(annotation) },
                    )
                }
            }
        }
    }
}

@Composable
private fun AnnotationRow(
    annotation: ReaderAnnotation,
    tags: List<String>,
    onJump: () -> Unit,
    onEdit: () -> Unit,
) {
    val palette = Hearth.palette
    val kind = AnnotationKind.parse(annotation.kind)
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier.fillMaxWidth()
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .clickable(onClick = onJump)
            .padding(Hearth.Spacing.M),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Box(
            Modifier.size(34.dp)
                .clip(CircleShape)
                .background(if (kind == AnnotationKind.HIGHLIGHT) annotationColor(annotation.colorHex) else palette.bg)
                .border(1.dp, palette.hairline, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(kind.label.take(1), style = HearthText.Label.copy(fontWeight = FontWeight.Bold), color = palette.text)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text(kind.label, style = HearthText.Caption.copy(fontWeight = FontWeight.SemiBold), color = palette.ember)
                Text(relativeTime(annotation.updatedAt), style = HearthText.Caption, color = palette.textTertiary)
            }
            annotation.selectedText.takeIf { it.isNotBlank() }?.let {
                Text(it, style = HearthText.Body, color = palette.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            annotation.note.takeIf { it.isNotBlank() }?.let {
                Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            val location = annotationLocation(annotation)
            if (location.isNotBlank()) Text(location, style = HearthText.Caption, color = palette.textTertiary)
            if (tags.isNotEmpty()) {
                Text(tags.joinToString(" · "), style = HearthText.Caption, color = palette.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Text(
            "Edit",
            style = HearthText.Caption.copy(fontWeight = FontWeight.SemiBold),
            color = palette.ember,
            modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onEdit).padding(horizontal = 8.dp, vertical = 5.dp),
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AnnotationEditDialog(
    annotation: ReaderAnnotation,
    currentTags: List<String>,
    knownTags: List<String>,
    onDismiss: () -> Unit,
    onJump: () -> Unit,
    onSave: (AnnotationStyle?, String?, String, List<String>) -> Unit,
    onDelete: () -> Unit,
) {
    val palette = Hearth.palette
    val kind = AnnotationKind.parse(annotation.kind)
    var note by remember(annotation.id) { mutableStateOf(annotation.note) }
    var tagsText by remember(annotation.id) { mutableStateOf(currentTags.joinToString(", ")) }
    var style by remember(annotation.id) { mutableStateOf(AnnotationStyle.parse(annotation.style)) }
    var colorHex by remember(annotation.id) { mutableStateOf(annotation.colorHex) }
    val parsedTags = parseTags(tagsText)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(kind.label) },
        text = {
            Column(
                Modifier.heightIn(max = 560.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
            ) {
                annotation.selectedText.takeIf { it.isNotBlank() }?.let {
                    Column(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(palette.bg)
                            .border(1.dp, palette.hairline, RoundedCornerShape(12.dp))
                            .padding(Hearth.Spacing.M),
                    ) {
                        Text(it, style = HearthText.Body, color = palette.text, maxLines = 6, overflow = TextOverflow.Ellipsis)
                    }
                }
                Text(annotationLocation(annotation), style = HearthText.Caption, color = palette.textTertiary)
                OutlinedTextField(
                    value = note,
                    onValueChange = { note = it.take(1500) },
                    label = { Text("Note") },
                    minLines = 4,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = tagsText,
                    onValueChange = { tagsText = it },
                    label = { Text("Tags") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                val tagSuggestions = knownTags.filter { it !in parsedTags }.take(10)
                if (tagSuggestions.isNotEmpty() || parsedTags.isNotEmpty()) {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                    ) {
                        parsedTags.forEach { tag ->
                            HearthChip("#$tag", selected = true, onClick = {
                                tagsText = (parsedTags - tag).joinToString(", ")
                            })
                        }
                        tagSuggestions.forEach { tag ->
                            HearthChip("#$tag", selected = false, onClick = {
                                tagsText = (parsedTags + tag).distinct().joinToString(", ")
                            })
                        }
                    }
                }
                if (kind == AnnotationKind.HIGHLIGHT) {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                    ) {
                        listOf(AnnotationStyle.HIGHLIGHT, AnnotationStyle.UNDERLINE, AnnotationStyle.STRIKETHROUGH, AnnotationStyle.SQUIGGLY).forEach { s ->
                            HearthChip(s.label, selected = style == s, onClick = { style = s })
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S), verticalAlignment = Alignment.CenterVertically) {
                        HighlightColors.forEach { hex ->
                            ColorSwatch(hex = hex, selected = colorHex.equals(hex, ignoreCase = true), onClick = { colorHex = hex })
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onSave(
                    if (kind == AnnotationKind.HIGHLIGHT) style else null,
                    if (kind == AnnotationKind.HIGHLIGHT) colorHex else null,
                    note.trim(),
                    parseTags(tagsText),
                )
            }) { Text("Save") }
        },
        dismissButton = {
            Row {
                TextButton(onClick = onDelete) { Text("Delete") }
                TextButton(onClick = onJump) { Text("Jump") }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

@Composable
private fun ColorSwatch(hex: String, selected: Boolean, onClick: () -> Unit) {
    val palette = Hearth.palette
    val shape = CircleShape
    Box(
        Modifier.size(32.dp)
            .clip(shape)
            .background(annotationColor(hex))
            .border(if (selected) 3.dp else 1.dp, if (selected) palette.ember else palette.hairline, shape)
            .clickable(onClick = onClick),
    )
}

private val HighlightColors = listOf("#FFF59D", "#FFD166", "#F5921A", "#90CAF9", "#A5D6A7", "#CE93D8")

private fun parseTags(text: String): List<String> =
    text.split(",")
        .map { it.trim().removePrefix("#") }
        .filter { it.isNotBlank() }
        .distinctBy { it.lowercase() }

private fun annotationLocation(annotation: ReaderAnnotation): String {
    val media = AnnotationMedia.parse(annotation.media)
    return when (media) {
        AnnotationMedia.AUDIOBOOK -> annotation.audioPositionMs?.let { fmtMillis(it) }
        AnnotationMedia.PDF -> annotation.pdfPage?.let { "Page ${it + 1}" }
        AnnotationMedia.CBZ -> annotation.cbzPage?.let { "Page ${it + 1}" }
        AnnotationMedia.EPUB -> annotation.totalProgression?.let { "${(it * 100).roundToInt()}%" }
    } ?: annotation.chapterId?.takeIf { it.isNotBlank() }
    ?: annotation.progression?.let { "${(it * 100).roundToInt()}%" }
    ?: media.name.lowercase().replaceFirstChar { it.titlecase() }
}

private fun fmtMillis(ms: Long): String {
    val sec = (ms / 1000).coerceAtLeast(0)
    val h = sec / 3600
    val m = (sec % 3600) / 60
    val s = sec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

private fun relativeTime(ms: Long): String =
    DateUtils.getRelativeTimeSpanString(ms, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()

private fun annotationColor(hex: String): Color =
    runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrDefault(Color(0xFFFFF59D))

@Composable
private fun MetadataEditDialog(
    book: Book,
    onDismiss: () -> Unit,
    onSave: (LibraryMetadataEdit) -> Unit,
) {
    var title by remember(book.id) { mutableStateOf(book.title) }
    var subtitle by remember(book.id) { mutableStateOf(book.subtitle.orEmpty()) }
    var author by remember(book.id) { mutableStateOf(book.author.orEmpty()) }
    var narrator by remember(book.id) { mutableStateOf(book.narrator.orEmpty()) }
    var seriesName by remember(book.id) { mutableStateOf(book.seriesName.orEmpty()) }
    var seriesNumber by remember(book.id) { mutableStateOf(book.seriesNumber.orEmpty()) }
    var publisher by remember(book.id) { mutableStateOf(book.publisher.orEmpty()) }
    var publishedDate by remember(book.id) { mutableStateOf(book.publishedDate.orEmpty()) }
    var isbn13 by remember(book.id) { mutableStateOf(book.isbn13.orEmpty()) }
    var language by remember(book.id) { mutableStateOf(book.language.orEmpty()) }
    var pageCount by remember(book.id) { mutableStateOf(book.pageCount?.toString().orEmpty()) }
    var categories by remember(book.id) { mutableStateOf(book.categories.joinToString(", ")) }
    var description by remember(book.id) { mutableStateOf(book.description.orEmpty()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Edit metadata") },
        text = {
            Column(
                Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                MetadataField("Title", title, { title = it })
                MetadataField("Subtitle", subtitle, { subtitle = it })
                MetadataField("Author", author, { author = it })
                MetadataField("Narrator", narrator, { narrator = it })
                MetadataField("Series", seriesName, { seriesName = it })
                MetadataField("Series #", seriesNumber, { seriesNumber = it })
                MetadataField("Publisher", publisher, { publisher = it })
                MetadataField("Published", publishedDate, { publishedDate = it })
                MetadataField("ISBN-13", isbn13, { isbn13 = it })
                MetadataField("Language", language, { language = it })
                MetadataField("Pages", pageCount, { pageCount = it })
                MetadataField("Categories", categories, { categories = it })
                MetadataField("Description", description, { description = it }, singleLine = false)
            }
        },
        confirmButton = {
            Button(onClick = {
                onSave(
                    LibraryMetadataEdit(
                        title = title.trim(),
                        subtitle = subtitle.blankToNull(),
                        author = author.blankToNull(),
                        narrator = narrator.blankToNull(),
                        description = description.blankToNull(),
                        seriesName = seriesName.blankToNull(),
                        seriesNumber = seriesNumber.blankToNull(),
                        publisher = publisher.blankToNull(),
                        publishedDate = publishedDate.blankToNull(),
                        isbn13 = isbn13.blankToNull(),
                        language = language.blankToNull(),
                        pageCount = pageCount.trim().toIntOrNull(),
                        categories = categories.split(",").mapNotNull { it.trim().takeIf(String::isNotBlank) },
                    )
                )
            }) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun MetadataField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    singleLine: Boolean = true,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = singleLine,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun MetadataMatchDialog(
    query: String,
    matches: List<LibraryMetadataMatch>,
    searching: Boolean,
    onQueryChange: (String) -> Unit,
    onApply: (LibraryMetadataMatch) -> Unit,
    onDismiss: () -> Unit,
) {
    val palette = Hearth.palette
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Find a better match") },
        text = {
            Column(
                Modifier.heightIn(max = 520.dp),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
            ) {
                OutlinedTextField(
                    value = query,
                    onValueChange = onQueryChange,
                    label = { Text("Search") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                if (searching) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        Text("Searching…", style = HearthText.Caption, color = palette.textSecondary)
                    }
                }
                LazyColumn(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    items(matches, key = { it.id }) { match ->
                        Column(
                            Modifier.fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .border(1.dp, palette.hairline, RoundedCornerShape(16.dp))
                                .clickable { onApply(match) }
                                .padding(Hearth.Spacing.M),
                        ) {
                            Text(match.title, style = HearthText.Label, color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            val source = match.sourceName.lowercase().replace('_', ' ').replaceFirstChar { it.titlecase() }
                            val byline = listOfNotNull(match.author, match.publishedYear?.toString(), source).joinToString(" · ")
                            if (byline.isNotBlank()) Text(byline, style = HearthText.Caption, color = palette.textSecondary)
                            Text("${(match.confidence * 100).toInt()}% · ${match.matchReason}", style = HearthText.Caption, color = palette.ember)
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
    )
}

@Composable
private fun EditionLinkDialog(
    book: Book,
    currentLinked: Book?,
    query: String,
    candidates: List<LibraryLinkCandidate>,
    loading: Boolean,
    onQueryChange: (String) -> Unit,
    onLink: (LibraryLinkCandidate) -> Unit,
    onUnlink: () -> Unit,
    onDismiss: () -> Unit,
) {
    val palette = Hearth.palette
    val filteredCandidates = candidates.filter { it.book.uniqueKey != currentLinked?.uniqueKey }
    val title = if (book.mediaType == AppMediaType.EBOOK) "Link audiobook" else "Link ebook"
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(
                Modifier.heightIn(max = 560.dp),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
            ) {
                Text(
                    "Choose the matching ${if (book.mediaType == AppMediaType.EBOOK) "audiobook" else "ebook"} from your library. Picking one replaces any existing link on either book.",
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                )
                currentLinked?.let { linked ->
                    Column(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .border(1.dp, palette.hairline, RoundedCornerShape(16.dp))
                            .padding(Hearth.Spacing.M),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text("Current link", style = HearthText.Caption, color = palette.ember)
                        Text(linked.title, style = HearthText.Label, color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        val byline = listOfNotNull(linked.author, linked.source.displayName).joinToString(" · ")
                        if (byline.isNotBlank()) {
                            Text(byline, style = HearthText.Caption, color = palette.textSecondary)
                        }
                    }
                }
                OutlinedTextField(
                    value = query,
                    onValueChange = onQueryChange,
                    label = { Text("Search library") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                if (loading) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        Text("Looking for candidates…", style = HearthText.Caption, color = palette.textSecondary)
                    }
                }
                when {
                    !loading && filteredCandidates.isEmpty() -> {
                        Text(
                            if (query.isBlank()) "No opposite-format books are available to link yet." else "No books match that search.",
                            style = HearthText.Body,
                            color = palette.textSecondary,
                        )
                    }
                    else -> {
                        LazyColumn(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                            items(filteredCandidates, key = { it.book.uniqueKey }) { candidate ->
                                Column(
                                    Modifier.fillMaxWidth()
                                        .clip(RoundedCornerShape(16.dp))
                                        .border(1.dp, palette.hairline, RoundedCornerShape(16.dp))
                                        .clickable { onLink(candidate) }
                                        .padding(Hearth.Spacing.M),
                                ) {
                                    Text(candidate.book.title, style = HearthText.Label, color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    val byline = listOfNotNull(candidate.book.author, candidate.book.seriesName, candidate.book.source.displayName).joinToString(" · ")
                                    if (byline.isNotBlank()) {
                                        Text(byline, style = HearthText.Caption, color = palette.textSecondary)
                                    }
                                    Text(linkConfidenceLabel(candidate.confidence), style = HearthText.Caption, color = palette.ember)
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            Row {
                if (currentLinked != null) {
                    TextButton(onClick = onUnlink) { Text("Unlink") }
                }
                TextButton(onClick = onDismiss) { Text("Close") }
            }
        },
    )
}

private fun linkConfidenceLabel(confidence: Int): String =
    when {
        confidence >= 88 -> "$confidence% automatic match"
        confidence > 0 -> "$confidence% weak match"
        else -> "Manual link"
    }

private fun supportsEditionLinking(book: Book): Boolean =
    book.mediaType == AppMediaType.EBOOK || book.mediaType == AppMediaType.AUDIOBOOK

private fun String.blankToNull(): String? =
    trim().takeIf { it.isNotBlank() }

@Composable
private fun ChaptersSection(
    b: Book,
    chapters: List<Chapter>,
    loading: Boolean,
    failed: Boolean,
    onRetry: () -> Unit,
    onListenAt: (Book, Long) -> Unit,
    canSeparate: (Chapter) -> Boolean,
    onSeparate: (Chapter) -> Unit,
) {
    val palette = Hearth.palette
    var expanded by remember { mutableStateOf(false) }
    var menuChapter by remember { mutableStateOf<Chapter?>(null) }
    var pendingSeparation by remember { mutableStateOf<Chapter?>(null) }
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.XL)) {
        ShelfHeader("Chapters", modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(Hearth.Spacing.S))
        when {
            loading -> Text("Looking for chapter marks…", style = HearthText.Caption, color = palette.textTertiary)
            failed -> Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Couldn't load chapters.",
                    style = HearthText.Body, color = palette.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                QuietButton(text = "Retry", onClick = onRetry)
            }
            chapters.isEmpty() -> Text(
                "This book arrived without chapter marks.",
                style = HearthText.Body, color = palette.textSecondary,
            )
            else -> {
                val currentSec = b.currentTime
                val shown = if (expanded) chapters else chapters.take(8)
                shown.forEachIndexed { i, ch ->
                    val current = currentSec in ch.startTime until ch.endTime && currentSec > 0
                    Box {
                        Row(
                            Modifier.fillMaxWidth()
                                .combinedClickable(
                                    onClick = { onListenAt(b, ch.startTime * 1000L) },
                                    onLongClick = { if (canSeparate(ch)) menuChapter = ch },
                                )
                                .padding(vertical = Hearth.Spacing.S),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                ch.title.ifBlank { "Chapter ${ch.index + 1}" },
                                style = HearthText.Body,
                                color = if (current) palette.ember else palette.text,
                                maxLines = 1, overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            Text(fmtChapter(ch.duration), style = HearthText.Caption, color = palette.textTertiary)
                        }
                        DropdownMenu(
                            expanded = menuChapter == ch,
                            onDismissRequest = { menuChapter = null },
                        ) {
                            DropdownMenuItem(
                                text = { Text("Separate into book") },
                                onClick = {
                                    menuChapter = null
                                    pendingSeparation = ch
                                },
                            )
                        }
                    }
                    if (i != shown.lastIndex) Box(Modifier.fillMaxWidth().height(1.dp).background(palette.hairline))
                }
                if (chapters.size > 8) {
                    Text(
                        if (expanded) "Fewer chapters" else "All ${chapters.size} chapters",
                        style = HearthText.Label, color = palette.ember,
                        modifier = Modifier.clip(RoundedCornerShape(50)).clickable { expanded = !expanded }
                            .padding(vertical = Hearth.Spacing.S),
                    )
                }
            }
        }
    }
    pendingSeparation?.let { chapter ->
        AlertDialog(
            onDismissRequest = { pendingSeparation = null },
            title = { Text("Separate into book?") },
            text = {
                Text("Makes \"${chapter.title.ifBlank { "Chapter ${chapter.index + 1}" }}\" its own book in your library. The audio file stays where it is.")
            },
            confirmButton = {
                TextButton(onClick = {
                    pendingSeparation = null
                    onSeparate(chapter)
                }) { Text("Separate") }
            },
            dismissButton = {
                TextButton(onClick = { pendingSeparation = null }) { Text("Cancel") }
            },
        )
    }
}

private fun fmtChapter(sec: Long): String {
    val h = sec / 3600
    val m = (sec % 3600) / 60
    return if (h > 0) "${h}h ${m}m" else "${m}m"
}

@Composable
private fun DetailHeader(b: Book, ambientColor: Color, onBack: () -> Unit) {
    val palette = Hearth.palette
    Box(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().statusBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(Hearth.Spacing.S)) {
                Icon(
                    Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back", tint = palette.text,
                    modifier = Modifier.clip(CircleShape).clickable(onClick = onBack).padding(Hearth.Spacing.S).size(26.dp),
                )
            }
            Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL), horizontalAlignment = Alignment.CenterHorizontally) {
                val coverWidth = if (b.mediaType == AppMediaType.EBOOK) 156.dp else 112.dp
                CoverTile(model = b.coverUrl, ambient = ambientColor, modifier = Modifier.width(coverWidth))
                Spacer(Modifier.height(Hearth.Spacing.M))
                Text(
                    b.title,
                    style = hearthDisplay(24.sp, FontWeight.Bold),
                    color = palette.text,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center,
                )
                b.author?.let {
                    Text(
                        it,
                        style = HearthText.Body,
                        color = palette.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = TextAlign.Center,
                    )
                }
                if (!b.narrator.isNullOrBlank() && b.mediaType != AppMediaType.EBOOK) {
                    Text("Read by ${b.narrator}", style = HearthText.Caption, color = palette.textTertiary, textAlign = TextAlign.Center)
                }
                b.seriesName?.let {
                    val seq = b.seriesNumber?.let { n -> " · #$n" } ?: ""
                    Text("$it$seq", style = HearthText.Caption, color = palette.ember, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

@Composable
private fun DetailActions(
    b: Book,
    chapters: List<Chapter>,
    linkedAudiobook: Book?,
    linkedEbook: Book?,
    onListen: (Book) -> Unit,
    onRead: (Book) -> Unit,
) {
    val palette = Hearth.palette
    val progress = HearthFormat.progress(b)
    val listenTarget = detailListenTarget(b, linkedAudiobook)
    val readTarget = if (b.mediaType == AppMediaType.EBOOK || b.hasEbook) b else linkedEbook
    val canListen = listenTarget != null
    val canRead = readTarget != null
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.L)) {
        if (progress > 0f) {
            Ribbon(progress = progress)
            Spacer(Modifier.height(Hearth.Spacing.XS))
            Text(
                detailStatusLine(b, chapters),
                style = HearthText.Caption,
                color = palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(Hearth.Spacing.M))
        }
        when {

            canListen && canRead && b.mediaType == AppMediaType.EBOOK ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                    ActionPill("Read", Icons.AutoMirrored.Outlined.MenuBook, { onRead(readTarget) }, Modifier.weight(1f))
                    ActionPill("Listen", Icons.Filled.PlayArrow, { onListen(listenTarget) }, Modifier.weight(1f))
                }
            canListen && canRead -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                ActionPill("Listen", Icons.Filled.PlayArrow, { onListen(listenTarget) }, Modifier.weight(1f))
                ActionPill("Read", Icons.AutoMirrored.Outlined.MenuBook, { onRead(readTarget) }, Modifier.weight(1f))
            }
            canListen -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                EmberButton(
                    text = "Listen",
                    onClick = { onListen(listenTarget) },
                    leadingIcon = Icons.Filled.PlayArrow,
                )
            }
            else -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                EmberButton(
                    text = "Read",
                    onClick = { readTarget?.let(onRead) },
                    leadingIcon = Icons.AutoMirrored.Outlined.MenuBook,
                )
            }
        }
    }
}

internal fun detailListenTarget(book: Book, linkedAudiobook: Book?): Book? =
    if (
        book.mediaType == AppMediaType.AUDIOBOOK ||
        book.hasAudio ||
        (book.source == BookSource.STORYTELLER && book.readAlongAvailable)
    ) book else linkedAudiobook

@Composable
private fun ActionPill(text: String, icon: ImageVector, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = if (eink.sharpCorners) RoundedCornerShape(0.dp) else RoundedCornerShape(50)
    Row(
        modifier
            .clip(shape)
            .background(if (eink.active) palette.bg else palette.ember)
            .then(if (eink.active) Modifier.border(2.dp, palette.ember, shape) else Modifier)
            .clickable(onClick = onClick)
            .padding(horizontal = Hearth.Spacing.L, vertical = 14.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val fg = if (eink.active) palette.ember else palette.readableOnEmber
        Icon(icon, contentDescription = null, tint = fg, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(Hearth.Spacing.S))
        Text(text, style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold), color = fg)
    }
}

private fun stripHtml(html: String): String =
    html.replace(Regex("(?i)<br\\s*/?>"), "\n")
        .replace(Regex("(?i)</p>"), "\n\n")
        .replace(Regex("<[^>]+>"), "")
        .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
        .replace("&quot;", "\"").replace("&#39;", "'").replace("&apos;", "'").replace("&nbsp;", " ")
        .replace(Regex("[ \\t]+"), " ")
        .replace(Regex("\\n{3,}"), "\n\n")
        .trim()

@Composable
private fun DetailDescription(text: String) {
    val palette = Hearth.palette
    var expanded by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.L)) {
        Overline("About")
        Spacer(Modifier.height(Hearth.Spacing.S))
        Text(
            text,
            style = HearthText.Body,
            color = palette.textSecondary,
            maxLines = if (expanded) Int.MAX_VALUE else 4,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.animateContentSize().clickable { expanded = !expanded },
        )
    }
}

@Composable
private fun AboutGrid(b: Book) {
    val palette = Hearth.palette
    val entries = buildList {
        if (b.mediaType != AppMediaType.EBOOK && b.duration > 0) add("Length" to durationHm(b.duration))
        b.pageCount?.takeIf { it > 0 }?.let { add("Pages" to it.toString()) }
        b.publishedDate?.take(4)?.takeIf { it.length == 4 }?.let { add("Year" to it) }
        b.primaryFileType?.takeIf { it.isNotBlank() }?.let { add("Format" to it.uppercase()) }
        b.language?.takeIf { it.isNotBlank() }?.let { add("Language" to it.uppercase()) }
        b.publisher?.takeIf { it.isNotBlank() }?.let { add("Publisher" to it) }
    }
    if (entries.isEmpty() && b.categories.isEmpty()) return
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.L), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        Overline("Details")
        entries.forEach { (label, value) ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(label, style = HearthText.Caption, color = palette.textTertiary)
                Text(value, style = HearthText.Caption, color = palette.text)
            }
        }
        if (b.categories.isNotEmpty()) {
            Text(b.categories.joinToString(" · "), style = HearthText.Caption, color = palette.textSecondary)
        }
    }
}

@Composable
private fun BookShelfRow(title: String, books: List<Book>, onOpen: (Book) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = Hearth.Spacing.XL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        ShelfHeader(title, modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL))
        LazyRow(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Hearth.Spacing.XL),
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        ) {
            items(books, key = { it.id + (it.connectionId ?: "") }) { book ->
                CoverTile(model = book.coverUrl, modifier = Modifier.width(108.dp).clickable { onOpen(book) })
            }
        }
    }
}

@Composable
private fun RelatedShelf(
    title: String,
    books: List<BookOrbitRelatedBook>,
    onOpen: (Int) -> Unit,
) {
    val palette = Hearth.palette
    Column(Modifier.fillMaxWidth().padding(top = Hearth.Spacing.XL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        ShelfHeader(title, modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL))
        LazyRow(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Hearth.Spacing.XL),
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        ) {
            items(books, key = { it.bookId }) { related ->
                Column(
                    Modifier.width(108.dp).clickable { onOpen(related.bookId) },
                    verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
                ) {
                    CoverTile(model = related.coverUrl, contentDescription = related.title)
                    Text(
                        related.title,
                        style = HearthText.Caption,
                        color = palette.text,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    related.seriesLabel?.let {
                        Text(it, style = HearthText.Caption, color = palette.textTertiary, maxLines = 1)
                    }
                }
            }
        }
    }
}

private fun relatedShelfTitle(source: BookSource): String = when (source) {
    BookSource.SILO -> "Silo suggests"
    else -> "You might also like"
}

private fun detailStatusLine(b: Book, chapters: List<Chapter>): String {
    val timeLeft = HearthFormat.timeLeft(b)
    if (chapters.isNotEmpty() && b.mediaType != AppMediaType.EBOOK) {
        val index = chapters.indexOfLast { it.startTime <= b.currentTime }.coerceAtLeast(0)
        val chapterLine = "Chapter ${index + 1} of ${chapters.size}"
        return listOfNotNull(chapterLine, timeLeft).joinToString(" · ")
    }
    val pct = (HearthFormat.progress(b) * 100).toInt()
    return if (b.isFinished) "Finished" else listOfNotNull("$pct% complete", timeLeft).joinToString(" · ")
}

private fun durationHm(seconds: Long): String {
    val h = seconds / 3600; val m = (seconds % 3600) / 60
    return if (h > 0) "${h}h ${m}m" else "${m}m"
}
