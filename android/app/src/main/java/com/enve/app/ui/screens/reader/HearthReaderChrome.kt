package com.enve.app.ui.screens.reader

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.ui.layout.layout
import androidx.compose.animation.core.tween
import androidx.compose.ui.graphics.Brush
import androidx.compose.material.icons.outlined.BookmarkAdd
import androidx.compose.material.icons.automirrored.outlined.StickyNote2
import androidx.compose.foundation.gestures.detectTapGestures
import com.enve.app.viewmodel.ChapterMark
import com.enve.app.viewmodel.PageMark
import androidx.compose.ui.text.style.TextOverflow
import kotlin.math.roundToInt
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.List
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.automirrored.outlined.Subject
import androidx.compose.material.icons.outlined.AutoStories
import androidx.compose.material.icons.outlined.Bookmark
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FormatStrikethrough
import androidx.compose.material.icons.outlined.FormatUnderlined
import androidx.compose.material.icons.outlined.Gesture
import androidx.compose.material.icons.outlined.Headphones
import androidx.compose.material.icons.outlined.KeyboardArrowUp
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.RecordVoiceOver
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.TextFields
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Icon
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.app.readium.narrator.NarratorPack
import com.enve.app.data.reader.ReaderTheme
import com.enve.app.ui.components.AnnotationEditSheet
import com.enve.app.ui.screens.PerBookAnnotationsSheet
import com.enve.app.ui.screens.ReaderStatusStrip
import com.enve.app.ui.screens.printedPageLabel
import com.enve.app.viewmodel.ReaderViewModel
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.Book
import com.enve.engine.prefs.ReadNextPosition
import com.enve.engine.theme.HearthPaletteStyle
import com.enve.hearth.design.EmberAccent
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthEink
import com.enve.hearth.design.HearthPalette
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalHearth
import com.enve.hearth.design.LocalHearthEink
import com.enve.hearth.design.Overline
import com.enve.hearth.design.parseHexColor

@Composable
fun HearthReaderChrome(
    vm: ReaderViewModel,
    bookTitle: String,
    bookAuthor: String,
    accentColor: Color,
    paletteStyle: HearthPaletteStyle,
    onBack: () -> Unit,
    onAskLibrarian: () -> Unit,
    onMarkFinished: suspend () -> Boolean,
    onVerticalMarginsChanged: (Float) -> Unit,
    einkActive: Boolean,
    readNextEnabled: Boolean = true,
    readNextPosition: ReadNextPosition = ReadNextPosition.BOTTOM,
    onReadNext: (Book) -> Unit = {},
    restReminder: ReaderRestReminderSpec,
) {
    val state by vm.state.collectAsStateWithLifecycle()
    val chromeInteraction by vm.chromeInteraction.collectAsStateWithLifecycle()
    val knownTags by vm.knownTags.collectAsStateWithLifecycle()
    val palette = readerChromePalette(state.prefs.theme, einkActive, accentColor, paletteStyle)
    val snackbarHostState = remember { SnackbarHostState() }
    val context = LocalContext.current

    LaunchedEffect(state.prefs.verticalMargins) {
        onVerticalMarginsChanged(state.prefs.verticalMargins)
    }
    LaunchedEffect(
        state.showChrome,
        state.showAppearanceSheet,
        state.showTocSheet,
        state.showSearchSheet,
        state.showAnnotationDialog,
        state.showAnnotationsSheet,
        state.showReadAloudSheet,
        state.showTtsSheet,
        state.showReadAloudLyrics,
        state.showMoreMenu,
        state.readAlongPreparing,
        state.liveReadAlongPreparing,
        chromeInteraction,
    ) {
        if (
            state.showChrome &&
            !state.showAppearanceSheet &&
            !state.showTocSheet &&
            !state.showSearchSheet &&
            !state.showAnnotationDialog &&
            !state.showAnnotationsSheet &&
            !state.showReadAloudSheet &&
            !state.showTtsSheet &&
            !state.showReadAloudLyrics &&
            !state.showMoreMenu &&
            !state.readAlongPreparing && !state.liveReadAlongPreparing
        ) {
            kotlinx.coroutines.delay(if (einkActive) 15_000L else CHROME_AUTO_HIDE_MS)
            vm.hideChrome()
        }
    }
    LaunchedEffect(state.transientMessage) {
        val message = state.transientMessage ?: return@LaunchedEffect
        snackbarHostState.showSnackbar(message = message, duration = SnackbarDuration.Short)
        vm.consumeTransientMessage()
    }
    LaunchedEffect(state.linkReturnLocator) {
        if (state.linkReturnLocator == null) return@LaunchedEffect
        val result = snackbarHostState.showSnackbar(
            message = "Opened linked section.",
            actionLabel = "Back to reading",
            duration = SnackbarDuration.Long,
        )
        if (result == SnackbarResult.ActionPerformed) vm.returnFromInternalLink() else vm.dismissInternalLinkReturn()
    }

    CompositionLocalProvider(
        LocalHearth provides palette,
        LocalHearthEink provides if (einkActive) HearthEink(com.enve.engine.eink.EinkState(true, palette.bg == Color.White, com.enve.engine.eink.EinkMode.ON, false, 2)) else HearthEink.Inactive,
    ) {
        Box(Modifier.fillMaxSize()) {
            val dimmer = readerDimmerAlpha(state.prefs.screenBrightness)
            if (dimmer > 0f) {
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = dimmer)))
            }

            if (state.prefs.showClock || state.prefs.showBattery ||
                state.prefs.progressDisplay != com.enve.app.data.reader.ReaderProgressDisplay.NONE) {
                ReaderStatusStrip(
                    showClock = state.prefs.showClock,
                    showBattery = state.prefs.showBattery,
                    progressDisplay = state.prefs.progressDisplay,
                    currentPage = state.currentPage,
                    totalPages = state.totalPages,
                    hasPageList = state.hasPageList,
                    currentPageLabel = state.currentPageLabel,
                    lastPageLabel = state.lastPageLabel,
                    progressPct = state.progressPct,
                    chapter = state.currentSection,
                    minutesLeft = state.minutesLeftInBook,
                    chromeVisible = state.showChrome,
                    textColor = palette.textSecondary,
                    modifier = Modifier.align(Alignment.TopCenter),
                )
            }

            if (einkActive) {
                if (state.showChrome) {
                    Box(Modifier.align(Alignment.TopCenter)) {
                        TopVeil(
                            title = bookTitle,
                            menuExpanded = state.showMoreMenu,
                            onMenuExpandedChange = vm::showMoreMenu,
                            onBack = onBack,
                            onBookmark = {
                                if (vm.addBookmark()) vm.postTransientMessage("Bookmark added.")
                                else vm.postTransientMessage("Reader is still loading.")
                            },
                            onAddNote = { vm.addStandaloneNote() },
                            onAnnotations = { vm.showAnnotationsSheet(true) },
                            onLibrarian = onAskLibrarian,
                            showContents = state.readAlongActive,
                            onContents = { vm.showToc(true) },
                        )
                    }
                }
            } else {
                AnimatedVisibility(
                    visible = state.showChrome,
                    enter = fadeIn(tween(CHROME_FADE_MS)) + slideInVertically(tween(CHROME_FADE_MS)) { -it / 6 },
                    exit = fadeOut(tween(CHROME_FADE_MS)) + slideOutVertically(tween(CHROME_FADE_MS)) { -it / 6 },
                    modifier = Modifier.align(Alignment.TopCenter),
                ) {
                    TopVeil(
                        title = bookTitle,
                        menuExpanded = state.showMoreMenu,
                        onMenuExpandedChange = vm::showMoreMenu,
                        onBack = onBack,
                        onBookmark = {
                            if (vm.addBookmark()) vm.postTransientMessage("Bookmark added.")
                            else vm.postTransientMessage("Reader is still loading.")
                        },
                        onAddNote = { vm.addStandaloneNote() },
                        onAnnotations = { vm.showAnnotationsSheet(true) },
                        onLibrarian = onAskLibrarian,
                        showContents = state.readAlongActive,
                        onContents = { vm.showToc(true) },
                    )
                }
            }

            if (state.showReadAloudLyrics) {
                HearthReadAloudLyrics(
                    rows = state.readAlongChapterClips,
                    activeIndex = state.readAlongClipIndex,
                    onSelect = { vm.jumpToReadAlongClip(it) },
                    onClose = { vm.showReadAloudLyrics(false) },
                    onToggleControls = vm::toggleChrome,
                    modifier = Modifier.matchParentSize(),
                )
            }

            if (state.showChrome && state.readAlongActive) {
                Box(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = Hearth.Spacing.M).fillMaxWidth()) {
                    ReadAloudBar(
                        playing = state.readAlongPlaying,
                        preparing = state.readAlongPreparing,
                        clip = state.readAlongClipIndex,
                        clipCount = state.readAlongClipCount,
                        onToggle = vm::toggleReadAlongPlayback,
                        onBack = vm::skipReadAlongBackward,
                        onForward = vm::skipReadAlongForward,
                        onTune = { vm.showReadAloudSheet(true) },
                        onLyrics = { vm.showReadAloudLyrics(!state.showReadAloudLyrics) },
                        onClose = vm::toggleReadAlongMode,
                    )
                }
            }

            val bottomVeil: @Composable () -> Unit = {
                Column {
                    if (state.liveReadAlongActive) {
                        HearthLinkedReadAlongPanel(
                            status = state.liveReadAlongStatus,
                            playing = state.liveReadAlongPlaying,
                            following = state.liveReadAlongFollowing,
                            finding = state.liveReadAlongFinding,
                            retryable = state.liveReadAlongRetryable,
                            onTogglePlayback = vm::toggleReadAlongPlayback,
                            onFollow = vm::resumeLiveReadAlongFollowing,
                            onListenHere = { vm.listenFromHere() },
                            onRetry = vm::retryLiveReadAlong,
                            onClose = vm::toggleReadAlongMode,
                        )
                    }
                    BottomVeil(
                        progress = state.progressPct / 100f,
                        summary = pageSummary(
                            state.currentPage,
                            state.totalPages,
                            state.hasPageList,
                            state.currentPageLabel,
                            state.lastPageLabel,
                            state.progressPct,
                            state.currentSection,
                            state.minutesLeftInBook,
                        ),
                        readAlongSupported = state.readAlongSupported || state.liveReadAlongAvailable,
                        onSeek = vm::seekToProgress,
                        onContents = { vm.showToc(true) },
                        onAppearance = { vm.showAppearance(true) },
                        onSearch = { vm.showSearch(true) },
                        chapterMarks = state.chapterMarks,
                        pageMarks = state.pageMarks,
                        totalPages = state.totalPages,
                        currentPage = state.currentPage,
                        onNarrate = vm::toggleReadAlongPlayback,
                        onReadBack = vm::toggleTtsPlayback,
                        ttsActive = state.ttsPlayback.active,
                        ttsControls = {
                            ReaderSpeechTransport(
                                playing = state.ttsPlayback.playing,
                                preparing = state.ttsPlayback.preparing,
                                narrated = false,
                                onToggle = vm::toggleTtsPlayback,
                                onBack = vm::previousTtsParagraph,
                                onForward = vm::nextTtsParagraph,
                                onSettings = { vm.showTtsSheet(true) },
                                pack = state.ttsNarratorPack,
                            )
                        },
                    )
                }
            }

            val live = state.liveReadAlongActive
            val narrated = state.readAlongActive || live
            AnimatedVisibility(
                visible = !state.showChrome && (narrated || (state.ttsPlayback.active && state.ttsControlsVisible)),
                enter = if (einkActive) EnterTransition.None else fadeIn() + slideInVertically { it / 2 },
                exit = if (einkActive) ExitTransition.None else fadeOut() + slideOutVertically { it / 2 },
                modifier = Modifier.align(Alignment.BottomCenter),
            ) {
                Box(Modifier.navigationBarsPadding().padding(Hearth.Spacing.M)) {
                    ReaderSpeechTransport(
                        playing = if (live) state.liveReadAlongPlaying else if (narrated) state.readAlongPlaying else state.ttsPlayback.playing,
                        preparing = if (live) state.liveReadAlongPreparing else if (narrated) state.readAlongPreparing else state.ttsPlayback.preparing,
                        narrated = narrated,
                        onToggle = if (narrated) vm::toggleReadAlongPlayback else vm::toggleTtsPlayback,
                        onBack = if (live) vm::skipLiveReadAlongBackward else if (narrated) vm::skipReadAlongBackward else vm::previousTtsParagraph,
                        onForward = if (live) vm::skipLiveReadAlongForward else if (narrated) vm::skipReadAlongForward else vm::nextTtsParagraph,
                        onSettings = { if (live) vm.toggleChrome() else if (narrated) vm.showReadAloudSheet(true) else vm.showTtsSheet(true) },
                        onShowControls = { vm.toggleChrome() },
                        pack = state.ttsNarratorPack.takeUnless { narrated },
                    )
                }
            }
            if (einkActive) {
                if (state.showChrome && !state.readAlongActive) {
                    Box(Modifier.align(Alignment.BottomCenter)) { bottomVeil() }
                }
            } else {
                AnimatedVisibility(
                    visible = state.showChrome && !state.readAlongActive,
                    enter = fadeIn(tween(CHROME_FADE_MS)) + slideInVertically(tween(CHROME_FADE_MS)) { it / 6 },
                    exit = fadeOut(tween(CHROME_FADE_MS)) + slideOutVertically(tween(CHROME_FADE_MS)) { it / 6 },
                    modifier = Modifier.align(Alignment.BottomCenter),
                ) {
                    bottomVeil()
                }
            }

            if (state.showSelectionPopup && state.pendingSelection != null) {
                SelectionPalette(
                    ink = vm.lastHighlightInk,
                    onInkChange = { vm.lastHighlightInk = it },
                    onApply = { style, hex ->
                        vm.addAnnotation(state.pendingSelection!!, style, hex, "", state.selectionText)
                        vm.hideSelectionPopup()
                    },
                    onCopy = {
                        copySelection(context, state.selectionText)
                        vm.hideSelectionPopup()
                        vm.clearSelection()
                    },
                    onNote = {
                        vm.hideSelectionPopup()
                        vm.showAnnotationDialog(true)
                    },
                    onDictionary = vm::define,
                    onShare = {
                        val quote = state.selectionText
                        if (quote.isNotBlank()) {
                            val intent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, "“$quote”\n- from $bookTitle")
                            }
                            context.startActivity(Intent.createChooser(intent, "Share quote"))
                        }
                        vm.hideSelectionPopup()
                        vm.clearSelection()
                    },
                    onSpeak = {
                        vm.speakSelection(state.selectionText)
                        vm.hideSelectionPopup()
                        vm.clearSelection()
                    },
                    onListen = if (state.liveReadAlongAvailable && !state.readAlongSupported) {
                        {
                            vm.listenFromSelection()
                            vm.hideSelectionPopup()
                            vm.clearSelection()
                        }
                    } else null,
                    modifier = state.selectionBounds?.let { Modifier.floatingNear(it) } ?: Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.L),
                )
            }

            val nextBook = state.nextInSeries
            val atEnd = state.totalPages > 0 && state.currentPage >= state.totalPages ||
                state.progressPct >= 98
            var finishedDismissed by remember { mutableStateOf(false) }
            if (atEnd && !finishedDismissed && !(readNextEnabled && nextBook != null) && !state.showChrome) {
                FinishedBookCard(
                    title = bookTitle,
                    onMarkFinished = onMarkFinished,
                    onDismiss = { finishedDismissed = true },
                    onLeave = onBack,
                    modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding()
                        .padding(bottom = Hearth.Spacing.XXL, start = Hearth.Spacing.XL, end = Hearth.Spacing.XL),
                )
            }
            if (readNextEnabled && nextBook != null && atEnd) {
                HearthReadNextButton(
                    book = nextBook,
                    onClick = { onReadNext(nextBook) },
                    modifier = Modifier
                        .align(
                            if (readNextPosition == ReadNextPosition.TOP) {
                                Alignment.TopCenter
                            } else {
                                Alignment.BottomCenter
                            },
                        )
                        .padding(
                            top = if (readNextPosition == ReadNextPosition.TOP) 108.dp else 0.dp,
                            bottom = if (readNextPosition == ReadNextPosition.BOTTOM) 108.dp else 0.dp,
                            start = Hearth.Spacing.XL,
                            end = Hearth.Spacing.XL,
                        ),
                )
            }

            ReaderRestReminder(
                spec = restReminder,
                modifier = Modifier
                    .align(Alignment.Center)
                    .padding(horizontal = Hearth.Spacing.XL),
            )

            HearthReaderSheets(vm = vm, state = state)
            if (state.showAnnotationsSheet) {
                PerBookAnnotationsSheet(
                    bookTitle = bookTitle,
                    bookAuthor = bookAuthor.takeIf { it.isNotBlank() },
                    annotations = state.annotations + state.bookmarks,
                    onDismiss = { vm.showAnnotationsSheet(false) },
                    onJumpTo = { ann ->
                        vm.seekToAnnotation(ann)
                        vm.showAnnotationsSheet(false)
                    },
                    onEdit = { ann ->
                        vm.showDecorationPopover(ann.id)
                        vm.showAnnotationsSheet(false)
                    },
                    onDelete = vm::deleteAnnotation,
                )
            }
            state.activeDecorationAnnotation?.let { ann ->
                val tags = remember(ann.id, ann.tagsJson) {
                    runCatching {
                        val arr = org.json.JSONArray(ann.tagsJson)
                        buildList {
                            for (i in 0 until arr.length()) {
                                arr.optString(i).takeIf { it.isNotBlank() }?.let(::add)
                            }
                        }
                    }.getOrDefault(emptyList())
                }
                AnnotationEditSheet(
                    annotation = ann,
                    initialTags = tags,
                    onDismiss = { vm.hideDecorationPopover() },
                    onSave = { style, color, note, newTags ->
                        vm.updateAnnotation(ann, style, color, note, newTags)
                        vm.hideDecorationPopover()
                    },
                    onDelete = {
                        vm.deleteAnnotation(ann)
                        vm.hideDecorationPopover()
                    },
                    onJumpTo = {
                        vm.seekToAnnotation(ann)
                        vm.hideDecorationPopover()
                    },
                    knownTags = knownTags,
                )
            }
            SnackbarHost(
                hostState = snackbarHostState,
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 104.dp),
            ) { data ->
                Snackbar(
                    containerColor = palette.bgElevated,
                    contentColor = palette.text,
                    action = data.visuals.actionLabel?.let { label ->
                        {
                            TextButton(onClick = data::performAction) {
                                Text(label, color = if (Hearth.eink.monochrome) palette.text else palette.ember)
                            }
                        }
                    },
                ) {
                    Text(data.visuals.message)
                }
            }
        }
    }
}

@Composable
private fun TopVeil(
    title: String,
    menuExpanded: Boolean,
    onMenuExpandedChange: (Boolean) -> Unit,
    onBack: () -> Unit,
    onBookmark: () -> Unit,
    onAddNote: () -> Unit,
    onAnnotations: () -> Unit,
    onLibrarian: () -> Unit,
    showContents: Boolean,
    onContents: () -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val haptics = rememberReaderHaptics()
    val background = if (eink.active) Modifier.background(palette.bg) else Modifier.background(
        Brush.verticalGradient(0f to palette.bg, 0.7f to palette.bg, 1f to palette.bg.copy(alpha = 0f)),
    )
    Column(Modifier.fillMaxWidth().then(background)) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding()
                .padding(start = Hearth.Spacing.S, end = Hearth.Spacing.S, top = Hearth.Spacing.XS, bottom = Hearth.Spacing.L),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GlyphBtn(Icons.AutoMirrored.Outlined.ArrowBack, "Close", onBack, palette.text)
            Spacer(Modifier.width(Hearth.Spacing.S))
            Overline(title, modifier = Modifier.weight(1f))
            GlyphBtn(Icons.Outlined.BookmarkAdd, "Bookmark this page", { haptics.confirm(); onBookmark() }, palette.textSecondary)
            Box {
                GlyphBtn(Icons.Outlined.MoreHoriz, "More", { onMenuExpandedChange(true) }, palette.textSecondary)
                DropdownMenu(
                    expanded = menuExpanded,
                    onDismissRequest = { onMenuExpandedChange(false) },
                    shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else Hearth.Radius.Card),
                    containerColor = palette.bgElevated,
                    border = androidx.compose.foundation.BorderStroke(1.dp, palette.hairline),
                    shadowElevation = if (eink.borderInsteadOfShadow) 0.dp else 8.dp,
                ) {
                    val item: @Composable (String, ImageVector, () -> Unit) -> Unit = { label, icon, action ->
                        DropdownMenuItem(
                            text = { Text(label, style = HearthText.Body) },
                            leadingIcon = { Icon(icon, contentDescription = null) },
                            onClick = { onMenuExpandedChange(false); action() },
                            colors = androidx.compose.material3.MenuDefaults.itemColors(
                                textColor = palette.text,
                                leadingIconColor = palette.textSecondary,
                            ),
                        )
                    }
                    if (showContents) item("Contents", Icons.AutoMirrored.Outlined.List, onContents)
                    item("New note", Icons.Outlined.Edit, onAddNote)
                    item("Notes & highlights", Icons.AutoMirrored.Outlined.StickyNote2, onAnnotations)
                    item("Ask the Librarian", Icons.Outlined.AutoStories, onLibrarian)
                }
            }
        }
        if (eink.active) Box(Modifier.fillMaxWidth().height(1.dp).background(palette.hairline))
    }
}

@Composable
private fun BottomVeil(
    progress: Float,
    summary: String,
    readAlongSupported: Boolean,
    onSeek: (Float) -> Unit,
    onContents: () -> Unit,
    onAppearance: () -> Unit,
    onSearch: () -> Unit,
    chapterMarks: List<ChapterMark>,
    pageMarks: List<PageMark>,
    totalPages: Int,
    currentPage: Int,
    onNarrate: () -> Unit,
    onReadBack: () -> Unit,
    ttsActive: Boolean,
    ttsControls: @Composable () -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    var preview by remember { mutableStateOf<Float?>(null) }
    val background = if (eink.active) Modifier.background(palette.bg) else Modifier.background(
        Brush.verticalGradient(0f to palette.bg.copy(alpha = 0f), 0.1f to palette.bg.copy(alpha = 0.88f), 0.18f to palette.bg),
    )
    Column(Modifier.fillMaxWidth().then(background)) {
        if (eink.active) Box(Modifier.fillMaxWidth().height(1.dp).background(palette.hairline))
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding()
                .padding(start = Hearth.Spacing.XL, end = Hearth.Spacing.XL, top = if (eink.active) Hearth.Spacing.M else Hearth.Spacing.XXL, bottom = Hearth.Spacing.S),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            ProgressRibbon(progress, chapterMarks, onPreview = { preview = it }, onSeek = onSeek)
            var chapterScope by rememberSaveable { mutableStateOf(false) }
            val chapterSummary = chapterPagesLeft(currentPage, totalPages, chapterMarks)
            Text(
                preview?.let { scrubPreview(it, chapterMarks, pageMarks, totalPages) }
                    ?: chapterSummary?.takeIf { chapterScope } ?: summary,
                style = HearthText.Caption.copy(fontFeatureSettings = "tnum"),
                color = if (preview != null) palette.text else palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth().then(
                    if (chapterSummary != null) {
                        Modifier.clickable(
                            role = Role.Button,
                            onClickLabel = if (chapterScope) "Show book position" else "Show pages left in chapter",
                        ) { chapterScope = !chapterScope }
                    } else Modifier,
                ),
            )
            if (ttsActive) Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { ttsControls() }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                ChromeBtn(Icons.AutoMirrored.Outlined.List, "Contents", onContents)
                ChromeBtn(Icons.Outlined.TextFields, "Appearance", onAppearance)
                ChromeBtn(Icons.Outlined.Search, "Search", onSearch)
                if (readAlongSupported) ChromeBtn(Icons.Outlined.RecordVoiceOver, "Read Aloud", onNarrate)
                else if (!ttsActive) ChromeBtn(Icons.Outlined.RecordVoiceOver, "Read back", onReadBack)
            }
        }
    }
}

private fun chapterPagesLeft(currentPage: Int, totalPages: Int, marks: List<ChapterMark>): String? {
    if (totalPages <= 0 || marks.isEmpty()) return null
    val fraction = currentPage.toFloat() / totalPages
    val next = marks.firstOrNull { it.start > fraction + 0.0005f }?.start ?: 1f
    val left = ((next * totalPages).roundToInt() - currentPage).coerceAtLeast(0)
    val chapter = marks.lastOrNull { it.start <= fraction + 0.0005f }?.title?.takeIf(String::isNotBlank)
    val pages = if (left == 1) "1 page left in chapter" else "$left pages left in chapter"
    return listOfNotNull(pages, chapter).joinToString(" · ")
}

private fun scrubPreview(fraction: Float, marks: List<ChapterMark>, pageMarks: List<PageMark>, totalPages: Int): String {
    val chapter = marks.lastOrNull { it.start <= fraction + 0.0005f }?.title
    val page = when {
        pageMarks.isNotEmpty() -> {
            val label = (pageMarks.lastOrNull { it.start <= fraction + 0.0005f } ?: pageMarks.first()).label
            "Page ${printedPageLabel(label)} of ${printedPageLabel(pageMarks.last().label)}"
        }
        totalPages > 0 -> "Location ${(fraction * totalPages).roundToInt().coerceIn(1, totalPages)} of $totalPages"
        else -> null
    }
    return listOfNotNull(page, "${(fraction * 100).roundToInt()}%", chapter?.takeIf(String::isNotBlank)).joinToString(" · ")
}

@Composable
private fun ProgressRibbon(
    progress: Float,
    chapterMarks: List<ChapterMark>,
    onPreview: (Float?) -> Unit,
    onSeek: (Float) -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val haptics = rememberReaderHaptics()
    var drag by remember { mutableStateOf<Float?>(null) }
    val shown = drag ?: progress.coerceIn(0f, 1f)
    val ticks = chapterMarks.map { it.start }.filter { it in 0.005f..0.995f }
    fun chapterAt(fraction: Float) = ticks.count { it <= fraction }
    Canvas(
        Modifier.fillMaxWidth().height(28.dp)
            .semantics { contentDescription = "Reading position ${(progress * 100).roundToInt()}%" }
            .pointerInput(ticks) {
                detectHorizontalDragGestures(
                    onDragStart = { o ->
                        val f = (o.x / size.width).coerceIn(0f, 1f)
                        drag = f
                        onPreview(f)
                        haptics.tick()
                    },
                    onHorizontalDrag = { c, _ ->
                        val previous = drag ?: 0f
                        val f = (c.position.x / size.width).coerceIn(0f, 1f)
                        if (chapterAt(f) != chapterAt(previous)) haptics.tick()
                        drag = f
                        onPreview(f)
                    },
                    onDragEnd = {
                        drag?.let(onSeek)
                        haptics.confirm()
                        drag = null
                        onPreview(null)
                    },
                    onDragCancel = { drag = null; onPreview(null) },
                )
            }
            .pointerInput(Unit) {
                detectTapGestures { o ->
                    haptics.confirm()
                    onSeek((o.x / size.width).coerceIn(0f, 1f))
                }
            },
    ) {
        val h = if (eink.active) 5.dp.toPx() else 3.dp.toPx()
        val y = size.height / 2f
        val fill = if (eink.monochrome) palette.text else palette.ember
        drawLine(palette.hairline, Offset(0f, y), Offset(size.width, y), h, StrokeCap.Round)
        drawLine(fill, Offset(0f, y), Offset(size.width * shown, y), h, StrokeCap.Round)
        ticks.forEach { tick ->
            val x = size.width * tick
            drawLine(if (tick <= shown) palette.bg.copy(alpha = 0.55f) else palette.textTertiary, Offset(x, y - h * 1.4f), Offset(x, y + h * 1.4f), 1.dp.toPx())
        }
        drawCircle(fill, if (drag != null) h * 2.6f else h * 1.9f, Offset(size.width * shown, y))
    }
}

@Composable
private fun Modifier.floatingNear(bounds: com.enve.app.ui.screens.reader.ReaderSelectionBounds): Modifier {
    val density = androidx.compose.ui.platform.LocalDensity.current
    val topInset = WindowInsets.statusBars.getTop(density)
    val bottomInset = WindowInsets.navigationBars.getBottom(density)
    return layout { measurable, constraints ->
        val margin = 16.dp.roundToPx()
        val gapAbove = 12.dp.roundToPx()
        val gapBelow = 28.dp.roundToPx()
        val palette = measurable.measure(constraints.copy(minWidth = 0, minHeight = 0, maxWidth = constraints.maxWidth - margin * 2))
        layout(constraints.maxWidth, constraints.maxHeight) {
            val above = bounds.top.roundToInt() - gapAbove - palette.height
            val below = bounds.bottom.roundToInt() + gapBelow
            val y = when {
                above >= topInset + margin -> above
                below + palette.height <= constraints.maxHeight - bottomInset - margin -> below
                else -> constraints.maxHeight - bottomInset - margin - palette.height
            }
            palette.place((constraints.maxWidth - palette.width) / 2, y)
        }
    }
}
private const val CHROME_AUTO_HIDE_MS = 3_500L
private const val CHROME_FADE_MS = 300

@Composable
private fun ReadAloudBar(
    playing: Boolean, preparing: Boolean, clip: Int, clipCount: Int,
    onToggle: () -> Unit, onBack: () -> Unit, onForward: () -> Unit,
    onTune: () -> Unit, onLyrics: () -> Unit, onClose: () -> Unit,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Bar)
    Row(
        Modifier.padding(horizontal = Hearth.Spacing.M).fillMaxWidth().clip(shape)
            .background(palette.bgElevated).border(1.dp, palette.hairline, shape)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.XS),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            if (preparing) "Preparing read aloud…" else "Clip ${clip + 1} / ${clipCount.coerceAtLeast(1)}",
            style = HearthText.Caption,
            color = palette.textSecondary,
            modifier = Modifier.weight(1f).padding(start = Hearth.Spacing.XS, end = Hearth.Spacing.XS),
        )
        GlyphBtn(Icons.Filled.SkipPrevious, "Previous clip", onBack, palette.text, enabled = !preparing)
        Box(
            Modifier.size(48.dp).clip(CircleShape)
                .clickable(enabled = !preparing, role = Role.Button, onClick = onToggle),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                if (playing) "Pause read aloud" else "Play read aloud",
                tint = palette.ember,
                modifier = Modifier.size(30.dp).alpha(if (preparing) 0.38f else 1f),
            )
        }
        GlyphBtn(Icons.Filled.SkipNext, "Next clip", onForward, palette.text, enabled = !preparing)
        GlyphBtn(Icons.AutoMirrored.Outlined.Subject, "Read mode", onLyrics, palette.textSecondary)
        GlyphBtn(Icons.Outlined.Tune, "Read aloud settings", onTune, palette.textSecondary)
        GlyphBtn(Icons.Outlined.Close, "Stop read aloud", onClose, palette.textSecondary)
    }
}

@Composable
internal fun ReaderSpeechTransport(
    playing: Boolean,
    preparing: Boolean,
    narrated: Boolean,
    onToggle: () -> Unit,
    onBack: () -> Unit,
    onForward: () -> Unit,
    onSettings: (() -> Unit)?,
    onShowControls: (() -> Unit)? = null,
    pack: NarratorPack? = null,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Bar)
    Column(
        Modifier.clip(shape).background(palette.bgElevated).border(1.dp, palette.hairline, shape),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (pack == NarratorPack.WOOF) WoofAttribution()
        Row(
            Modifier.padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.XS),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GlyphBtn(Icons.Filled.SkipPrevious, if (narrated) "Previous clip" else "Previous paragraph", onBack, palette.text, !preparing)
            GlyphBtn(
                if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                if (playing) "Pause read back" else "Resume read back",
                onToggle,
                palette.ember,
            )
            GlyphBtn(Icons.Filled.SkipNext, if (narrated) "Next clip" else "Next paragraph", onForward, palette.text, !preparing)
            onSettings?.let { GlyphBtn(Icons.Outlined.Tune, if (narrated) "Read aloud settings" else "Voice and speed", it, palette.textSecondary) }
            onShowControls?.let { GlyphBtn(Icons.Outlined.KeyboardArrowUp, "Show reader controls", it, palette.textSecondary) }
        }
    }
}

@Composable
private fun SelectionPalette(
    ink: String,
    onInkChange: (String) -> Unit,
    onApply: (AnnotationStyle, String) -> Unit,
    onCopy: () -> Unit,
    onNote: () -> Unit,
    onDictionary: () -> Unit,
    onShare: () -> Unit,
    onSpeak: () -> Unit,
    onListen: (() -> Unit)?,
    modifier: Modifier,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val haptics = rememberReaderHaptics()
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else 28.dp)
    var moreMenu by remember { mutableStateOf(false) }
    Row(
        modifier.clip(shape)
            .background(palette.bgElevated.copy(alpha = if (eink.active) 1f else 0.98f))
            .border(1.dp, palette.hairline, shape)
            .padding(horizontal = Hearth.Spacing.S, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SELECTION_INKS.forEach { hex ->
            InkSwatch(hex, ink == hex) {
                haptics.confirm()
                onInkChange(hex)
                onApply(AnnotationStyle.HIGHLIGHT, hex)
            }
        }
        Box(Modifier.padding(horizontal = Hearth.Spacing.XS).width(1.dp).height(24.dp).background(palette.hairline))
        StyleGlyph(Icons.Outlined.Edit, "Note", onNote)
        StyleGlyph(Icons.Outlined.ContentCopy, "Copy") { haptics.confirm(); onCopy() }
        StyleGlyph(Icons.AutoMirrored.Outlined.MenuBook, "Define", onDictionary)
        Box {
            StyleGlyph(Icons.Outlined.MoreHoriz, "More") { moreMenu = true }
            DropdownMenu(
                expanded = moreMenu,
                onDismissRequest = { moreMenu = false },
                shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else Hearth.Radius.Card),
                containerColor = palette.bgElevated,
                border = androidx.compose.foundation.BorderStroke(1.dp, palette.hairline),
            ) {
                val item: @Composable (String, ImageVector, () -> Unit) -> Unit = { label, icon, action ->
                    DropdownMenuItem(
                        text = { Text(label, style = HearthText.Body) },
                        leadingIcon = { Icon(icon, contentDescription = null) },
                        onClick = { moreMenu = false; action() },
                        colors = androidx.compose.material3.MenuDefaults.itemColors(
                            textColor = palette.text,
                            leadingIconColor = palette.textSecondary,
                        ),
                    )
                }
                item("Underline", Icons.Outlined.FormatUnderlined) { haptics.confirm(); onApply(AnnotationStyle.UNDERLINE, ink) }
                item("Strikethrough", Icons.Outlined.FormatStrikethrough) { haptics.confirm(); onApply(AnnotationStyle.STRIKETHROUGH, ink) }
                item("Squiggle", Icons.Outlined.Gesture) { haptics.confirm(); onApply(AnnotationStyle.SQUIGGLY, ink) }
                item("Share", Icons.Outlined.Share, onShare)
                item("Speak", Icons.Outlined.RecordVoiceOver, onSpeak)
                onListen?.let { item("Listen from here", Icons.Outlined.Headphones, it) }
            }
        }
    }
}

private val SELECTION_INKS = listOf("#FFF59D", "#A5D6A7", "#90CAF9", "#F8BBD0")

@Composable
private fun StyleGlyph(icon: ImageVector, cd: String, onClick: () -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else Hearth.Radius.Inner)
    Box(
        Modifier.size(44.dp).clip(shape)
            .clickable(role = Role.Button, onClickLabel = cd, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, cd, tint = palette.textSecondary, modifier = Modifier.size(21.dp))
    }
}

@Composable
private fun InkSwatch(hex: String, selected: Boolean, onClick: () -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val ring = if (eink.monochrome) palette.text else palette.ember
    val label = annotationColorLabel(hex)
    Box(
        Modifier.size(40.dp).clip(CircleShape)
            .clickable(role = Role.Button, onClickLabel = "Highlight in $label", onClick = onClick)
            .semantics { contentDescription = "Highlight in $label" },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(26.dp).clip(CircleShape).background(parseHexColor(hex) ?: EmberAccent)
                .border(if (selected) 2.dp else 1.dp, if (selected) ring else palette.hairline, CircleShape),
        )
    }
}

@Composable
private fun ChromeBtn(icon: ImageVector, label: String, onClick: () -> Unit) {
    val palette = Hearth.palette
    Column(
        Modifier.clip(RoundedCornerShape(Hearth.Radius.Inner)).clickable(onClick = onClick).padding(Hearth.Spacing.S),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(icon, label, tint = palette.textSecondary, modifier = Modifier.size(22.dp))
        Text(label, style = HearthText.Overline, color = palette.textSecondary)
    }
}

@Composable
private fun GlyphBtn(icon: ImageVector, cd: String, onClick: () -> Unit, tint: Color, enabled: Boolean = true) {
    Box(
        Modifier.size(48.dp).clip(CircleShape).clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            cd,
            tint = tint.copy(alpha = if (enabled) tint.alpha else tint.alpha * 0.38f),
            modifier = Modifier.size(24.dp),
        )
    }
}

private fun pageSummary(
    page: Int,
    total: Int,
    hasPageList: Boolean,
    currentPageLabel: String?,
    lastPageLabel: String?,
    pct: Int,
    section: String,
    minutesRemaining: Int?,
): String {
    val position = com.enve.app.ui.screens.readerPositionText(
        page,
        total,
        hasPageList,
        currentPageLabel,
        lastPageLabel,
    )
    val loc = if (position.isNotEmpty()) "$position · $pct%" else "$pct%"

    val left = minutesRemaining?.let { " · ${com.enve.app.ui.screens.readingTimeLeft(it)}" }.orEmpty()
    return if (section.isNotBlank()) "$loc$left · $section" else "$loc$left"
}

private fun copySelection(context: Context, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("Quote", text))
}

private fun readerDimmerAlpha(screenBrightness: Float): Float {
    if (screenBrightness < 0f) return 0f
    return (1f - screenBrightness.coerceIn(0.05f, 1f)).coerceIn(0f, 0.82f)
}

private fun annotationColorLabel(hex: String): String = when (hex.uppercase()) {
    "#FFF59D" -> "Yellow"
    "#A5D6A7" -> "Green"
    "#90CAF9" -> "Blue"
    "#F8BBD0" -> "Pink"
    "#FFCC80" -> "Orange"
    "#CE93D8" -> "Purple"
    else -> hex
}

internal fun readerChromePalette(
    theme: ReaderTheme,
    eink: Boolean,
    accent: Color,
    style: HearthPaletteStyle,
): HearthPalette = when {
    eink -> HearthPalette.eink()
    theme == ReaderTheme.LIGHT -> HearthPalette.paper(accent, style)
    theme == ReaderTheme.SEPIA -> HearthPalette.paper(accent, style).copy(
        bg = Color(0xFFF3E8D0), bgElevated = Color(0xFFEDD9B4), bgSunken = Color(0xFFE8DCC0),
        text = Color(0xFF4A3F30), textSecondary = Color(0xFF6E5F49), textTertiary = Color(0xFF9A8968),
    )
    theme == ReaderTheme.OLED -> HearthPalette.oled(accent, style)
    else -> HearthPalette.ink(accent, style)
}
