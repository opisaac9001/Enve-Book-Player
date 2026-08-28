package com.enve.app.ui.screens.reader

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.animation.AnimatedVisibility
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
import androidx.compose.material.icons.outlined.AutoStories
import androidx.compose.material.icons.outlined.Bookmark
import androidx.compose.material.icons.outlined.BorderColor
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FormatStrikethrough
import androidx.compose.material.icons.outlined.FormatUnderlined
import androidx.compose.material.icons.outlined.Gesture
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
import androidx.compose.material3.Text
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.app.data.reader.ReaderTheme
import com.enve.app.ui.components.AnnotationEditSheet
import com.enve.app.ui.screens.PerBookAnnotationsSheet
import com.enve.app.ui.screens.ReaderStatusStrip
import com.enve.app.viewmodel.ReaderViewModel
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.Book
import com.enve.engine.prefs.ReadNextPosition
import com.enve.hearth.design.EmberAccent
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthEink
import com.enve.hearth.design.HearthPalette
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalHearth
import com.enve.hearth.design.LocalHearthEink
import com.enve.hearth.design.Overline
import com.enve.hearth.design.hearthDisplay

private val INKS = listOf("#FFF59D", "#A5D6A7", "#90CAF9", "#F8BBD0", "#FFCC80", "#CE93D8")

@Composable
fun HearthReaderChrome(
    vm: ReaderViewModel,
    bookTitle: String,
    bookAuthor: String,
    accentColor: Color,
    onBack: () -> Unit,
    onAskLibrarian: () -> Unit,
    onVerticalMarginsChanged: (Float) -> Unit,
    einkActive: Boolean,
    readNextEnabled: Boolean = true,
    readNextPosition: ReadNextPosition = ReadNextPosition.BOTTOM,
    onReadNext: (Book) -> Unit = {},
) {
    val state by vm.state.collectAsStateWithLifecycle()
    val knownTags by vm.knownTags.collectAsStateWithLifecycle()
    val palette = readerChromePalette(state.prefs.theme, einkActive, accentColor)
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
        state.showMoreMenu,
        state.readAlongPreparing,
    ) {
        if (
            state.showChrome &&
            !state.showAppearanceSheet &&
            !state.showTocSheet &&
            !state.showSearchSheet &&
            !state.showAnnotationDialog &&
            !state.showAnnotationsSheet &&
            !state.showReadAloudSheet &&
            !state.showMoreMenu &&
            !state.readAlongPreparing
        ) {
            kotlinx.coroutines.delay(if (einkActive) 15_000L else 5_000L)
            vm.hideChrome()
        }
    }
    LaunchedEffect(state.transientMessage) {
        val message = state.transientMessage ?: return@LaunchedEffect
        snackbarHostState.showSnackbar(message = message, duration = SnackbarDuration.Short)
        vm.consumeTransientMessage()
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
                            onAppearance = { vm.showAppearance(true) },
                            onSearch = { vm.showSearch(true) },
                            onLibrarian = onAskLibrarian,
                        )
                    }
                }
            } else {
                AnimatedVisibility(
                    visible = state.showChrome,
                    enter = slideInVertically { -it },
                    exit = slideOutVertically { -it },
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
                        onAppearance = { vm.showAppearance(true) },
                        onSearch = { vm.showSearch(true) },
                        onLibrarian = onAskLibrarian,
                    )
                }
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
                        onClose = vm::toggleReadAlongMode,
                    )
                }
            }

            val bottomVeil: @Composable () -> Unit = {
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
                    ),
                    readAlongSupported = state.readAlongSupported,
                    onSeek = vm::seekToProgress,
                    onContents = { vm.showToc(true) },
                    onBookmark = {
                        if (vm.addBookmark()) vm.postTransientMessage("Bookmark added.")
                        else vm.postTransientMessage("Reader is still loading.")
                    },
                    onAnnotations = { vm.showAnnotationsSheet(true) },
                    onNarrate = vm::toggleReadAlongPlayback,
                )
            }
            if (einkActive) {
                if (state.showChrome && !state.readAlongActive) {
                    Box(Modifier.align(Alignment.BottomCenter)) { bottomVeil() }
                }
            } else {
                AnimatedVisibility(
                    visible = state.showChrome && !state.readAlongActive,
                    enter = slideInVertically { it },
                    exit = slideOutVertically { it },
                    modifier = Modifier.align(Alignment.BottomCenter),
                ) {
                    bottomVeil()
                }
            }

            if (state.showSelectionPopup && state.pendingSelection != null) {
                SelectionPalette(
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
                    onDictionary = {
                        val word = state.selectionText.trim()
                        vm.saveToVocab()
                        vm.hideSelectionPopup()
                        if (word.isNotBlank()) vm.postTransientMessage("Saved “$word” to Vocabulary.")
                    },
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
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.L),
                )
            }

            val nextBook = state.nextInSeries
            val atEnd = state.totalPages > 0 && state.currentPage >= state.totalPages ||
                state.progressPct >= 98
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
    onAppearance: () -> Unit,
    onSearch: () -> Unit,
    onLibrarian: () -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    Column(Modifier.fillMaxWidth().background(palette.bg.copy(alpha = if (eink.active) 1f else 0.94f))) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding()
                .padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GlyphBtn(Icons.AutoMirrored.Outlined.ArrowBack, "Close", onBack, palette.text)
            Spacer(Modifier.width(Hearth.Spacing.S))
            Overline(title, modifier = Modifier.weight(1f))
            Box {
                GlyphBtn(Icons.Outlined.MoreHoriz, "More", { onMenuExpandedChange(true) }, palette.textSecondary)
                DropdownMenu(expanded = menuExpanded, onDismissRequest = { onMenuExpandedChange(false) }) {
                    DropdownMenuItem(
                        text = { Text("Add bookmark") },
                        leadingIcon = { Icon(Icons.Outlined.Bookmark, contentDescription = null) },
                        onClick = { onMenuExpandedChange(false); onBookmark() },
                    )
                    DropdownMenuItem(
                        text = { Text("New note") },
                        leadingIcon = { Icon(Icons.Outlined.Edit, contentDescription = null) },
                        onClick = { onMenuExpandedChange(false); onAddNote() },
                    )
                    DropdownMenuItem(
                        text = { Text("Notes & Highlights") },
                        leadingIcon = { Icon(Icons.AutoMirrored.Outlined.List, contentDescription = null) },
                        onClick = { onMenuExpandedChange(false); onAnnotations() },
                    )
                    DropdownMenuItem(
                        text = { Text("Appearance") },
                        leadingIcon = { Icon(Icons.Outlined.TextFields, contentDescription = null) },
                        onClick = { onMenuExpandedChange(false); onAppearance() },
                    )
                    DropdownMenuItem(
                        text = { Text("Search") },
                        leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
                        onClick = { onMenuExpandedChange(false); onSearch() },
                    )
                    DropdownMenuItem(
                        text = { Text("Ask the Librarian") },
                        leadingIcon = { Icon(Icons.Outlined.AutoStories, contentDescription = null) },
                        onClick = { onMenuExpandedChange(false); onLibrarian() },
                    )
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
    onBookmark: () -> Unit,
    onAnnotations: () -> Unit,
    onNarrate: () -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    Column(Modifier.fillMaxWidth().background(palette.bg.copy(alpha = if (eink.active) 1f else 0.94f))) {
        if (eink.active) Box(Modifier.fillMaxWidth().height(1.dp).background(palette.hairline))
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding()
                .padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.M),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            ProgressRibbon(progress, onSeek)
            Text(summary, style = HearthText.Caption, color = palette.textSecondary)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                ChromeBtn(Icons.AutoMirrored.Outlined.List, "Contents", onContents)
                ChromeBtn(Icons.Outlined.Bookmark, "Bookmark", onBookmark)
                ChromeBtn(Icons.Outlined.Edit, "Notes", onAnnotations)
                if (readAlongSupported) ChromeBtn(Icons.Outlined.RecordVoiceOver, "Read Aloud", onNarrate)
            }
        }
    }
}

@Composable
private fun ProgressRibbon(progress: Float, onSeek: (Float) -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    var drag by remember { mutableStateOf<Float?>(null) }
    val shown = drag ?: progress.coerceIn(0f, 1f)
    Canvas(
        Modifier.fillMaxWidth().height(20.dp).pointerInput(Unit) {
            detectHorizontalDragGestures(
                onDragStart = { o -> drag = (o.x / size.width).coerceIn(0f, 1f) },
                onHorizontalDrag = { c, _ -> drag = (c.position.x / size.width).coerceIn(0f, 1f) },
                onDragEnd = { drag?.let(onSeek); drag = null },
                onDragCancel = { drag = null },
            )
        },
    ) {
        val h = if (eink.active) 5.dp.toPx() else 3.dp.toPx()
        val y = size.height / 2f
        val fill = if (eink.monochrome) palette.text else palette.ember
        drawLine(palette.hairline, Offset(0f, y), Offset(size.width, y), h, StrokeCap.Round)
        drawLine(fill, Offset(0f, y), Offset(size.width * shown, y), h, StrokeCap.Round)
        drawCircle(fill, h * 1.8f, Offset(size.width * shown, y))
    }
}

@Composable
private fun ReadAloudBar(
    playing: Boolean, preparing: Boolean, clip: Int, clipCount: Int,
    onToggle: () -> Unit, onBack: () -> Unit, onForward: () -> Unit,
    onTune: () -> Unit, onClose: () -> Unit,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Bar)
    Row(
        Modifier.padding(horizontal = Hearth.Spacing.XL).fillMaxWidth().clip(shape)
            .background(palette.bgElevated).border(1.dp, palette.hairline, shape)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Text(if (preparing) "Preparing read aloud…" else "Clip ${clip + 1} / ${clipCount.coerceAtLeast(1)}", style = HearthText.Caption, color = palette.textSecondary, modifier = Modifier.weight(1f))
        GlyphBtn(Icons.Filled.SkipPrevious, "Previous clip", onBack, palette.text, enabled = !preparing)
        Icon(
            if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, "Play/Pause", tint = palette.ember,
            modifier = Modifier.clip(CircleShape).clickable(enabled = !preparing, onClick = onToggle).size(30.dp)
                .alpha(if (preparing) 0.38f else 1f),
        )
        GlyphBtn(Icons.Filled.SkipNext, "Next clip", onForward, palette.text, enabled = !preparing)
        GlyphBtn(Icons.Outlined.Tune, "Read aloud settings", onTune, palette.textSecondary)
        GlyphBtn(Icons.Outlined.Close, "Stop read aloud", onClose, palette.textSecondary)
    }
}

@Composable
private fun SelectionPalette(
    onApply: (AnnotationStyle, String) -> Unit,
    onCopy: () -> Unit,
    onNote: () -> Unit,
    onDictionary: () -> Unit,
    onShare: () -> Unit,
    onSpeak: () -> Unit,
    modifier: Modifier,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else Hearth.Radius.Card)
    var ink by remember { mutableStateOf(INKS.first()) }
    var moreMenu by remember { mutableStateOf(false) }
    Column(
        modifier.widthIn(max = 440.dp).clip(shape)
            .background(palette.bgElevated.copy(alpha = if (eink.active) 1f else 0.97f))
            .border(1.dp, palette.hairline, shape)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
        ) {
            StyleGlyph(Icons.Outlined.BorderColor, "Highlight") {
                onApply(AnnotationStyle.HIGHLIGHT, ink)
            }
            StyleGlyph(Icons.Outlined.FormatUnderlined, "Underline") {
                onApply(AnnotationStyle.UNDERLINE, ink)
            }
            StyleGlyph(Icons.Outlined.FormatStrikethrough, "Strikethrough") {
                onApply(AnnotationStyle.STRIKETHROUGH, ink)
            }
            StyleGlyph(Icons.Outlined.Gesture, "Squiggly") {
                onApply(AnnotationStyle.SQUIGGLY, ink)
            }
            Box(Modifier.padding(horizontal = Hearth.Spacing.XS).width(1.dp).height(26.dp).background(palette.hairline))
            INKS.forEach { hex -> InkSwatch(hex, ink == hex) { ink = hex } }
        }
        Box(Modifier.fillMaxWidth().padding(vertical = Hearth.Spacing.XS).height(1.dp).background(palette.hairline))
        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
        ) {
            PaletteAction(Icons.Outlined.ContentCopy, "Copy", onCopy)
            PaletteAction(Icons.Outlined.Edit, "Note", onNote)
            PaletteAction(Icons.AutoMirrored.Outlined.MenuBook, "Dictionary", onDictionary)
            Box {
                PaletteAction(Icons.Outlined.MoreHoriz, "More", { moreMenu = true })
                DropdownMenu(
                    expanded = moreMenu,
                    onDismissRequest = { moreMenu = false },
                    containerColor = palette.bgElevated,
                ) {
                    DropdownMenuItem(
                        text = { Text("Share", color = palette.text) },
                        leadingIcon = {
                            Icon(Icons.Outlined.Share, contentDescription = null, tint = palette.textSecondary)
                        },
                        onClick = { moreMenu = false; onShare() },
                    )
                    DropdownMenuItem(
                        text = { Text("Speak", color = palette.text) },
                        leadingIcon = {
                            Icon(Icons.Outlined.RecordVoiceOver, contentDescription = null, tint = palette.textSecondary)
                        },
                        onClick = { moreMenu = false; onSpeak() },
                    )
                }
            }
        }
    }
}

@Composable
private fun StyleGlyph(icon: ImageVector, cd: String, onClick: () -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else Hearth.Radius.Inner)
    Box(
        Modifier.size(44.dp).clip(shape)
            .clickable(onClick = onClick),
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
        Modifier.size(44.dp).clip(CircleShape).clickable(onClick = onClick)
            .semantics { contentDescription = "$label ink" },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(26.dp).clip(CircleShape).background(parseHex(hex))
                .border(if (selected) 2.dp else 1.dp, if (selected) ring else palette.hairline, CircleShape),
        )
    }
}

@Composable
private fun PaletteAction(icon: ImageVector, label: String, onClick: () -> Unit, emphasized: Boolean = false) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else Hearth.Radius.Inner)
    val tint = when {
        emphasized && eink.monochrome -> palette.text
        emphasized -> palette.ember
        else -> palette.textSecondary
    }
    Column(
        Modifier.clip(shape).clickable(onClick = onClick)
            .padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.XS)
            .widthIn(min = 52.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(icon, label, tint = tint, modifier = Modifier.size(20.dp))
        Text(label, style = HearthText.Overline, color = if (emphasized) tint else palette.textSecondary)
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
    Icon(
        icon,
        cd,
        tint = tint.copy(alpha = if (enabled) tint.alpha else tint.alpha * 0.38f),
        modifier = Modifier.clip(CircleShape).clickable(enabled = enabled, onClick = onClick)
            .padding(Hearth.Spacing.S).size(24.dp),
    )
}

private fun pageSummary(
    page: Int,
    total: Int,
    hasPageList: Boolean,
    currentPageLabel: String?,
    lastPageLabel: String?,
    pct: Int,
    section: String,
): String {
    val position = com.enve.app.ui.screens.readerPositionText(
        page,
        total,
        hasPageList,
        currentPageLabel,
        lastPageLabel,
    )
    val loc = if (position.isNotEmpty()) "$position · $pct%" else "$pct%"

    val left = if (total > 0 && page in 1..total) {
        val mins = ((total - page) * 3) / 2
        if (mins >= 60) " · ~${mins / 60}h ${mins % 60}m left" else " · ~${mins}m left"
    } else ""
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

internal fun parseHex(hex: String): Color {
    val v = hex.removePrefix("#").toLongOrNull(16) ?: return EmberAccent
    return Color(0xFF000000 or v)
}

internal fun readerChromePalette(theme: ReaderTheme, eink: Boolean, accent: Color): HearthPalette = when {
    eink -> HearthPalette.eink()
    theme == ReaderTheme.LIGHT -> HearthPalette.paper(accent)
    theme == ReaderTheme.SEPIA -> HearthPalette.paper(accent).copy(
        bg = Color(0xFFF3E8D0), bgElevated = Color(0xFFEDD9B4), bgSunken = Color(0xFFE8DCC0),
        text = Color(0xFF4A3F30), textSecondary = Color(0xFF6E5F49), textTertiary = Color(0xFF9A8968),
    )
    theme == ReaderTheme.OLED -> HearthPalette.oled(accent)
    else -> HearthPalette.ink(accent)
}
