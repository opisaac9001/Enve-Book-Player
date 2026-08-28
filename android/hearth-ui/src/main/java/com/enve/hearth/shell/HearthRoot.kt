package com.enve.hearth.shell

import androidx.activity.compose.BackHandler
import com.enve.core.data.playback.CastBlockedSignal
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.ImageLoader
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import com.enve.hearth.design.EmberAccent
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthEink
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.HearthTheme
import com.enve.hearth.design.LocalHearthImageLoader
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.bookorbit.BookOrbitAchievementsScreen
import com.enve.hearth.bookorbit.BookOrbitHighlightsScreen
import com.enve.hearth.bookorbit.BookOrbitInsightsScreen
import com.enve.hearth.detail.BookDetailScreen
import com.enve.hearth.home.HearthHomeScreen
import com.enve.hearth.journal.HearthCompletionCenterScreen
import com.enve.hearth.journal.HearthInsightsScreen
import com.enve.hearth.journal.HearthJournalScreen
import com.enve.hearth.journal.HearthStatsHubScreen
import com.enve.hearth.library.HearthLibraryScreen
import com.enve.hearth.player.PlayerScreen
import com.enve.hearth.player.HearthSleepInsightsScreen
import com.enve.hearth.settings.HearthSettingsDestination
import com.enve.hearth.settings.HearthSettingsScreen
import com.enve.engine.prefs.HearthStartTab

@Composable
fun HearthRoot(
    imageLoader: ImageLoader? = null,
    initialShowSettings: Boolean = false,
    showPlayerRequest: Boolean = false,
    onPlayerRequestConsumed: () -> Unit = {},
    onOpenEbook: (Book) -> Unit = {},
    onOpenAnnotation: (Book, ReaderAnnotation) -> Unit = { book, _ -> onOpenEbook(book) },
    onAskLibrarian: (Book) -> Unit = {},
    onManageSources: () -> Unit = {},
    onOpenSettingsDestination: (HearthSettingsDestination) -> Unit = {},
    playerTopAction: @Composable () -> Unit = {},
) {
    val vm: HearthShellViewModel = hiltViewModel()
    val mode by vm.themeMode.collectAsStateWithLifecycle()
    val oled by vm.oled.collectAsStateWithLifecycle()
    val uiTextScale by vm.uiTextScale.collectAsStateWithLifecycle()
    val reduceMotion by vm.reduceMotion.collectAsStateWithLifecycle()
    val accentHex by vm.accentHex.collectAsStateWithLifecycle()
    val einkState by vm.einkState.collectAsStateWithLifecycle()
    val nowPlaying by vm.nowPlaying.collectAsStateWithLifecycle()
    val lastOpenedBook by vm.lastOpenedBook.collectAsStateWithLifecycle()
    val transport by vm.transport.collectAsStateWithLifecycle()
    val currentChapter by vm.currentChapter.collectAsStateWithLifecycle()
    val preferredStartTab by vm.preferredStartTab.collectAsStateWithLifecycle()

    HearthTheme(
        mode = mode,
        accent = accentColor(accentHex),
        oledEnabled = oled,
        uiTextScale = uiTextScale,
        reduceMotion = reduceMotion,
        eink = HearthEink(einkState),
    ) {

        var mantelBarHeightPx by remember { mutableStateOf(0) }
        val mantelInset = if (mantelBarHeightPx > 0) {
            with(LocalDensity.current) { mantelBarHeightPx.toDp() }
        } else 96.dp
        CompositionLocalProvider(
            LocalHearthImageLoader provides imageLoader,
            LocalMantelInset provides mantelInset,
        ) {
            val palette = Hearth.palette
            var tab by rememberSaveable { mutableStateOf(HearthTab.HEARTH) }
            var startupTabApplied by rememberSaveable { mutableStateOf(false) }
            var showPlayer by rememberSaveable { mutableStateOf(false) }
            var showSettings by rememberSaveable { mutableStateOf(initialShowSettings) }
            var showCompletionCenter by rememberSaveable { mutableStateOf(false) }
            var showInsights by rememberSaveable { mutableStateOf(false) }
            var showStatsHub by rememberSaveable { mutableStateOf(false) }
            var showSleepInsights by rememberSaveable { mutableStateOf(false) }
            var showBookOrbitInsights by rememberSaveable { mutableStateOf(false) }
            var showBookOrbitAchievements by rememberSaveable { mutableStateOf(false) }
            var showBookOrbitHighlights by rememberSaveable { mutableStateOf(false) }
            var detailBook by remember { mutableStateOf<Book?>(null) }
            var castBlockedTitle by remember { mutableStateOf<String?>(null) }
            LaunchedEffect(preferredStartTab, startupTabApplied) {
                val preferred = preferredStartTab
                if (!startupTabApplied && preferred != null) {
                    tab = preferred.toHearthTab()
                    startupTabApplied = true
                }
            }
            LaunchedEffect(Unit) {
                CastBlockedSignal.events.collect { title ->
                    castBlockedTitle = title
                }
            }
            castBlockedTitle?.let { title ->
                AlertDialog(
                    onDismissRequest = { castBlockedTitle = null },
                    title = { Text("Can't cast this book") },
                    text = {
                        Text(
                            if (title.isBlank()) {
                                "Because of a Chromecast limitation, only books streamed from a connected server can be cast. Books added through Direct Upload can't be cast."
                            } else {
                                "\u201C$title\u201D can't be cast. Because of a Chromecast limitation, only books streamed from a connected server can be cast. Books added through Direct Upload aren't supported."
                            }
                        )
                    },
                    confirmButton = {
                        TextButton(onClick = { castBlockedTitle = null }) { Text("OK") }
                    },
                    containerColor = palette.bgElevated,
                    titleContentColor = palette.text,
                    textContentColor = palette.textSecondary,
                )
            }
            var pendingPlayerBookId by remember { mutableStateOf<String?>(null) }
            LaunchedEffect(showPlayerRequest, nowPlaying) {
                if (showPlayerRequest && nowPlaying != null) {
                    showPlayer = true
                    onPlayerRequestConsumed()
                }
            }
            LaunchedEffect(nowPlaying, showPlayer, pendingPlayerBookId) {
                val pending = pendingPlayerBookId
                if (nowPlaying == null && pending == null) showPlayer = false
                if (showPlayer && pending != null && nowPlaying?.bookId == pending) {
                    pendingPlayerBookId = null
                    detailBook = null
                }
            }
            val bookOrbitOverlayVisible = showBookOrbitInsights || showBookOrbitAchievements || showBookOrbitHighlights
            BackHandler(
                enabled = showPlayer || showSettings || showCompletionCenter || showInsights ||
                    showStatsHub || showSleepInsights || bookOrbitOverlayVisible || detailBook != null || tab != HearthTab.HEARTH,
            ) {
                when {
                    showPlayer -> {
                        showPlayer = false
                        pendingPlayerBookId = null
                    }
                    showSettings -> showSettings = false
                    detailBook != null -> detailBook = null
                    showBookOrbitInsights -> showBookOrbitInsights = false
                    showBookOrbitAchievements -> showBookOrbitAchievements = false
                    showBookOrbitHighlights -> showBookOrbitHighlights = false
                    showInsights -> showInsights = false
                    showStatsHub -> showStatsHub = false
                    showSleepInsights -> showSleepInsights = false
                    showCompletionCenter -> showCompletionCenter = false
                    tab != HearthTab.HEARTH -> tab = HearthTab.HEARTH
                }
            }

            val playBook: (Book) -> Unit = { book ->
                if (book.mediaType == AppMediaType.EBOOK) {
                    onOpenEbook(book)
                } else {
                    pendingPlayerBookId = book.id
                    vm.openAudio(book)
                    showPlayer = true
                }
            }
            val mantelBook = lastOpenedBook
            val lastOpenedIsActiveAudio = mantelBook?.let { book ->
                book.mediaType != AppMediaType.EBOOK && nowPlaying?.bookKey == book.uniqueKey
            } == true
            val openMantelItem: () -> Unit = {
                when {
                    mantelBook?.mediaType == AppMediaType.EBOOK -> onOpenEbook(mantelBook)
                    mantelBook != null && !lastOpenedIsActiveAudio -> playBook(mantelBook)
                    nowPlaying != null -> showPlayer = true
                }
            }
            val activateMantelItem: () -> Unit = {
                when {
                    mantelBook?.mediaType == AppMediaType.EBOOK -> onOpenEbook(mantelBook)
                    lastOpenedIsActiveAudio || (mantelBook == null && nowPlaying != null) -> vm.togglePlayPause()
                    mantelBook != null -> playBook(mantelBook)
                }
            }
            val selectBook: (Book) -> Unit = { detailBook = it }
            val jumpToAnnotation: (Book, ReaderAnnotation) -> Unit = { book, annotation ->
                val positionMs = annotation.audioPositionMs
                if (AnnotationMedia.parse(annotation.media) == AnnotationMedia.AUDIOBOOK || positionMs != null) {
                    pendingPlayerBookId = book.id
                    vm.openAudioAt(book, positionMs ?: 0L)
                    showPlayer = true
                } else {
                    onOpenAnnotation(book, annotation)
                    detailBook = null
                }
            }

            val einkOn = einkState.active
            val view = androidx.compose.ui.platform.LocalView.current
            LaunchedEffect(
                tab,
                showPlayer,
                detailBook != null,
                showSettings,
                showCompletionCenter,
                showInsights,
                showSleepInsights,
                bookOrbitOverlayVisible,
            ) {
                if (einkOn) vm.requestEinkRefresh(view)
            }
            val motionDisabled = einkOn || reduceMotion
            val enterT = if (motionDisabled) androidx.compose.animation.EnterTransition.None else slideInVertically { it }
            val exitT = if (motionDisabled) androidx.compose.animation.ExitTransition.None else slideOutVertically { it }

            Box(Modifier.fillMaxSize().background(palette.bg)) {
                when (tab) {
                    HearthTab.HEARTH -> HearthHomeScreen(
                        isPlaying = transport.isPlaying && lastOpenedIsActiveAudio,
                        onSelectBook = selectBook,
                        onPlayBook = playBook,
                        onOpenSettings = { showSettings = true },
                    )
                    HearthTab.LIBRARY -> HearthLibraryScreen(
                        onSelectBook = selectBook,
                        onPlayBook = playBook,
                        onPlaybackStarted = { showPlayer = true },
                        onAddSource = onManageSources,
                        onOpenSettings = { showSettings = true },
                    )
                    HearthTab.JOURNAL -> HearthJournalScreen(
                        onSelectBook = selectBook,
                        onOpenCompletions = { showCompletionCenter = true },
                        onOpenInsights = { showInsights = true },
                        onOpenStatsHub = { showStatsHub = true },
                        onOpenSleep = { showSleepInsights = true },
                        onOpenSettings = { showSettings = true },
                    )
                }
                MantelBar(
                    selected = tab,
                    onSelect = { tab = it },
                    lastOpenedBook = lastOpenedBook,
                    nowPlaying = nowPlaying,
                    transport = transport,
                    subtitle = currentChapter,
                    onOpenItem = openMantelItem,
                    onItemAction = activateMantelItem,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .onSizeChanged { mantelBarHeightPx = it.height },
                )

                AnimatedVisibility(
                    visible = showInsights,
                    enter = enterT,
                    exit = exitT,
                ) {
                    HearthInsightsScreen(
                        onBack = { showInsights = false },
                        onSelectBook = {
                            showInsights = false
                            detailBook = it
                        },
                    )
                }

                AnimatedVisibility(
                    visible = showStatsHub,
                    enter = enterT,
                    exit = exitT,
                ) {
                    HearthStatsHubScreen(
                        onBack = { showStatsHub = false },
                        onOpenBookOrbit = {
                            showBookOrbitInsights = true
                        },
                    )
                }

                AnimatedVisibility(
                    visible = showSleepInsights,
                    enter = enterT,
                    exit = exitT,
                ) {
                    HearthSleepInsightsScreen(onBack = { showSleepInsights = false })
                }

                AnimatedVisibility(
                    visible = showBookOrbitInsights,
                    enter = enterT,
                    exit = exitT,
                ) {
                    BookOrbitInsightsScreen(
                        onBack = { showBookOrbitInsights = false },
                        onOpenBook = {
                            showBookOrbitInsights = false
                            detailBook = it
                        },
                    )
                }

                AnimatedVisibility(
                    visible = showBookOrbitAchievements,
                    enter = enterT,
                    exit = exitT,
                ) {
                    BookOrbitAchievementsScreen(onBack = { showBookOrbitAchievements = false })
                }

                AnimatedVisibility(
                    visible = showBookOrbitHighlights,
                    enter = enterT,
                    exit = exitT,
                ) {
                    BookOrbitHighlightsScreen(
                        onBack = { showBookOrbitHighlights = false },
                        onOpenBook = {
                            showBookOrbitHighlights = false
                            detailBook = it
                        },
                    )
                }

                AnimatedVisibility(
                    visible = showCompletionCenter,
                    enter = enterT,
                    exit = exitT,
                ) {
                    HearthCompletionCenterScreen(
                        onBack = { showCompletionCenter = false },
                        onSelectBook = {
                            showCompletionCenter = false
                            detailBook = it
                        },
                    )
                }

                AnimatedVisibility(
                    visible = detailBook != null,
                    enter = enterT,
                    exit = exitT,
                ) {
                    detailBook?.let { b ->
                        BookDetailScreen(
                            initial = b,
                            onBack = {
                                detailBook = null
                                pendingPlayerBookId = null
                            },
                            onListen = {
                                pendingPlayerBookId = it.id
                                vm.openAudio(it)
                                showPlayer = true
                            },
                            onListenAt = { book, positionMs ->
                                pendingPlayerBookId = book.id
                                vm.openAudioAt(book, positionMs)
                                showPlayer = true
                            },
                            onRead = { onOpenEbook(it); detailBook = null },
                            onOpenBook = { detailBook = it },
                            onAskLibrarian = onAskLibrarian,
                            onOpenAnnotation = jumpToAnnotation,
                        )
                    }
                }

                AnimatedVisibility(
                    visible = showSettings,
                    enter = enterT,
                    exit = exitT,
                ) {
                    HearthSettingsScreen(
                        onBack = { showSettings = false },
                        onManageSources = onManageSources,
                        onOpenDestination = onOpenSettingsDestination,
                    )
                }

                AnimatedVisibility(
                    visible = showPlayer && nowPlaying != null && (pendingPlayerBookId == null || nowPlaying?.bookId == pendingPlayerBookId),
                    enter = enterT,
                    exit = exitT,
                ) {
                    PlayerScreen(
                        onDismiss = {
                            showPlayer = false
                            pendingPlayerBookId = null
                        },
                        topAction = playerTopAction,
                    )
                }

                val playbackNotice by vm.playbackNotice.collectAsStateWithLifecycle()
                playbackNotice?.let { msg ->
                    LaunchedEffect(msg) {
                        kotlinx.coroutines.delay(4000)
                        vm.dismissPlaybackNotice()
                    }
                    NoticeCapsule(
                        msg,
                        Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = LocalMantelInset.current + Hearth.Spacing.S),
                    )
                }
            }
        }
    }
}

private fun HearthStartTab.toHearthTab(): HearthTab = when (this) {
    HearthStartTab.HEARTH -> HearthTab.HEARTH
    HearthStartTab.LIBRARY -> HearthTab.LIBRARY
    HearthStartTab.JOURNAL -> HearthTab.JOURNAL
}

@Composable
private fun NoticeCapsule(text: String, modifier: Modifier = Modifier) {
    val palette = Hearth.palette
    val shape = if (Hearth.eink.sharpCorners) RectangleShape else RoundedCornerShape(999.dp)
    Box(
        modifier
            .padding(horizontal = 32.dp)
            .clip(shape)
            .background(palette.bgElevated)
            .border(0.5.dp, palette.hairline, shape)
            .padding(horizontal = 18.dp, vertical = 10.dp),
    ) {
        Text(text, style = HearthText.Caption, color = palette.text)
    }
}

private fun accentColor(hex: String): Color {
    val cleaned = hex.trim().removePrefix("#")
    if (cleaned.length != 6) return EmberAccent
    val value = cleaned.toLongOrNull(16) ?: return EmberAccent
    return Color(0xFF000000 or value)
}
