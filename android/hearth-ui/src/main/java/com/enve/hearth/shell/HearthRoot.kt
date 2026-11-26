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
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.dp
import com.enve.hearth.shell.profileViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.ImageLoader
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
import com.enve.hearth.bookorbit.BookOrbitBookDropScreen
import com.enve.hearth.bookorbit.BookOrbitHighlightsScreen
import com.enve.hearth.bookorbit.BookOrbitInsightsScreen
import com.enve.hearth.bookorbit.BookOrbitSmartScopesScreen
import com.enve.hearth.bookorbit.BookOrbitTool
import com.enve.hearth.design.parseHexColor
import com.enve.hearth.detail.BookDetailScreen
import com.enve.hearth.hasPlayableAudio
import com.enve.hearth.opensInPlayer
import com.enve.hearth.home.HearthHomeScreen
import com.enve.hearth.journal.HearthCompletionCenterScreen
import com.enve.hearth.journal.HearthInsightsScreen
import com.enve.hearth.journal.HearthJournalScreen
import com.enve.hearth.journal.HearthReadingRecapScreen
import com.enve.hearth.journal.HearthStatsHubScreen
import com.enve.hearth.library.HearthLibraryScreen
import com.enve.hearth.listeningposition.ListeningPositionScanScreen
import com.enve.hearth.player.PlayerScreen
import com.enve.hearth.podcasts.PodcastShowScreen
import com.enve.hearth.podcasts.PodcastEpisodeScreen
import com.enve.hearth.podcasts.PodcastsScreen
import com.enve.hearth.podcasts.isPodcastShow
import com.enve.hearth.player.HearthSleepInsightsScreen
import com.enve.hearth.settings.HearthSettingsDestination
import com.enve.hearth.settings.HearthSettingsScreen
import com.enve.engine.prefs.HearthStartTab

@Composable
fun HearthRoot(
    imageLoader: ImageLoader? = null,
    onOpenProfiles: (() -> Unit)? = null,
    profileName: String? = null,
    initialShowSettings: Boolean = false,
    showLibraryRequest: Boolean = false,
    onLibraryRequestConsumed: () -> Unit = {},
    showPlayerRequest: Boolean = false,
    onPlayerRequestConsumed: () -> Unit = {},
    positionLinkRequest: String? = null,
    onPositionLinkConsumed: () -> Unit = {},
    clubs: com.enve.engine.clubs.ClubsFacade? = null,
    clubBooks: kotlinx.coroutines.flow.Flow<List<Book>>? = null,
    clubInviteRequest: String? = null,
    onClubInviteConsumed: () -> Unit = {},
    openBookRequest: Book? = null,
    onBookRequestConsumed: () -> Unit = {},
    onOpenEbook: (Book) -> Unit = {},
    onOpenEbookPassage: (Book, String) -> Unit = { book, _ -> onOpenEbook(book) },
    onOpenAnnotation: (Book, ReaderAnnotation) -> Unit = { book, _ -> onOpenEbook(book) },
    onAskLibrarian: (Book) -> Unit = {},
    onManageSources: () -> Unit = {},
    onOpenSettingsDestination: (HearthSettingsDestination) -> Unit = {},
    onOpdsAuthorize: (connectionId: String, methodType: String, authorizeUrl: String) -> Unit = { _, _, _ -> },
    playerTopAction: @Composable () -> Unit = {},
    playerOverlay: @Composable () -> Unit = {},
) {
    val vm: HearthShellViewModel = profileViewModel()
    val mode by vm.themeMode.collectAsStateWithLifecycle()
    val oled by vm.oled.collectAsStateWithLifecycle()
    val paletteStyle by vm.paletteStyle.collectAsStateWithLifecycle()
    val uiTextScale by vm.uiTextScale.collectAsStateWithLifecycle()
    val reduceMotion by vm.reduceMotion.collectAsStateWithLifecycle()
    val accentHex by vm.accentHex.collectAsStateWithLifecycle()
    val einkState by vm.einkState.collectAsStateWithLifecycle()
    val nowPlaying by vm.nowPlaying.collectAsStateWithLifecycle()
    val lastOpenedBook by vm.lastOpenedBook.collectAsStateWithLifecycle()
    val transport by vm.transport.collectAsStateWithLifecycle()
    val currentChapter by vm.currentChapter.collectAsStateWithLifecycle()
    val preferredStartTab by vm.preferredStartTab.collectAsStateWithLifecycle()
    val showDockBookShortcut by vm.showDockBookShortcut.collectAsStateWithLifecycle()
    val activeDownloads by vm.activeDownloads.collectAsStateWithLifecycle()
    val readingEnabled by vm.readingEnabled.collectAsStateWithLifecycle()

    HearthTheme(
        mode = mode,
        accent = parseHexColor(accentHex) ?: EmberAccent,
        oledEnabled = oled,
        paletteStyle = paletteStyle,
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
            var showClubs by rememberSaveable { mutableStateOf(false) }
            var clubCode by rememberSaveable { mutableStateOf<String?>(null) }
            var clubBook by remember { mutableStateOf<Book?>(null) }
            LaunchedEffect(clubInviteRequest, clubs?.available) {
                if (clubInviteRequest != null && clubs?.available == true) {
                    clubCode = clubInviteRequest
                    clubBook = null
                    showClubs = true
                    onClubInviteConsumed()
                }
            }
            val closeClubs = {
                showClubs = false
                clubCode = null
                clubBook = null
            }
            var showSettings by rememberSaveable { mutableStateOf(initialShowSettings) }
            var showCompletionCenter by rememberSaveable { mutableStateOf(false) }
            var showInsights by rememberSaveable { mutableStateOf(false) }
            var showRecaps by rememberSaveable { mutableStateOf(false) }
            var showStatsHub by rememberSaveable { mutableStateOf(false) }
            var showSleepInsights by rememberSaveable { mutableStateOf(false) }
            var bookOrbitTool by rememberSaveable { mutableStateOf<BookOrbitTool?>(null) }
            var bookOrbitAccountId by rememberSaveable { mutableStateOf<String?>(null) }
            var detailBook by remember { mutableStateOf<Book?>(null) }
            var episodeBook by remember { mutableStateOf<Book?>(null) }
            var castBlockedTitle by remember { mutableStateOf<String?>(null) }
            LaunchedEffect(showLibraryRequest) {
                if (showLibraryRequest) {
                    showSettings = false
                    showPlayer = false
                    showCompletionCenter = false
                    showInsights = false
                    showRecaps = false
                    showStatsHub = false
                    showSleepInsights = false
                    bookOrbitTool = null
                    detailBook = null
                    episodeBook = null
                    tab = HearthTab.LIBRARY
                    startupTabApplied = true
                    onLibraryRequestConsumed()
                }
            }
            LaunchedEffect(openBookRequest) {
                if (openBookRequest != null) {
                    showSettings = false
                    detailBook = openBookRequest
                    onBookRequestConsumed()
                }
            }
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
            var positionLink by remember { mutableStateOf<String?>(null) }
            LaunchedEffect(positionLinkRequest) {
                if (positionLinkRequest != null) {
                    positionLink = positionLinkRequest
                    onPositionLinkConsumed()
                }
            }
            LaunchedEffect(showPlayerRequest, nowPlaying) {
                if (showPlayerRequest && nowPlaying != null) {
                    showPlayer = true
                    onPlayerRequestConsumed()
                }
            }
            val listPaneWidth = HearthPanes.listPaneWidth(
                with(LocalDensity.current) { LocalWindowInfo.current.containerSize.width.toDp() },
            )
            val smartScopesOpen = bookOrbitTool == BookOrbitTool.SMART_SCOPES
            val detailInPane = listPaneWidth != null &&
                (smartScopesOpen || (tab == HearthTab.LIBRARY && bookOrbitTool == null))
            LaunchedEffect(nowPlaying, showPlayer, pendingPlayerBookId) {
                val pending = pendingPlayerBookId
                if (nowPlaying == null && pending == null) showPlayer = false
                if (showPlayer && pending != null && nowPlaying?.bookId == pending) {
                    pendingPlayerBookId = null
                    if (detailBook?.isPodcastShow != true && !detailInPane) detailBook = null
                }
            }
            LifecycleEventEffect(Lifecycle.Event.ON_START) { vm.replayPendingEdits() }
            val openBookOrbitTool: (BookOrbitTool, String?) -> Unit = { tool, accountId ->
                showSettings = false
                if (detailInPane) detailBook = null
                bookOrbitAccountId = accountId
                bookOrbitTool = tool
            }
            val bookOrbitOverlayVisible = bookOrbitTool != null
            val overlayVisible = showClubs || showPlayer || showSettings || showCompletionCenter || showInsights || showRecaps ||
                showStatsHub || showSleepInsights || bookOrbitOverlayVisible || detailBook != null || episodeBook != null
            BackHandler(enabled = overlayVisible || tab != HearthTab.HEARTH) {
                when {
                    showClubs -> closeClubs()
                    showPlayer -> {
                        showPlayer = false
                        pendingPlayerBookId = null
                    }
                    showSettings -> showSettings = false
                    episodeBook != null -> episodeBook = null
                    detailBook != null -> detailBook = null
                    bookOrbitTool != null -> bookOrbitTool = null
                    showRecaps -> showRecaps = false
                    showInsights -> showInsights = false
                    showStatsHub -> showStatsHub = false
                    showSleepInsights -> showSleepInsights = false
                    showCompletionCenter -> showCompletionCenter = false
                    tab != HearthTab.HEARTH -> tab = HearthTab.HEARTH
                }
            }

            val listenBook: (Book) -> Unit = { book ->
                pendingPlayerBookId = book.id
                vm.openAudio(book)
                showPlayer = true
            }
            val playBook: (Book) -> Unit = { book ->
                when {
                    book.mediaType == AppMediaType.EBOOK && readingEnabled -> onOpenEbook(book)
                    !book.hasPlayableAudio || book.isPodcastShow -> detailBook = book
                    else -> listenBook(book)
                }
            }
            val mantelBook = lastOpenedBook
            val lastOpenedIsActiveAudio = mantelBook?.let { book ->
                nowPlaying?.bookKey == book.uniqueKey
            } == true
            val openMantelItem: () -> Unit = {
                when {
                    lastOpenedIsActiveAudio -> showPlayer = true
                    mantelBook != null -> playBook(mantelBook)
                    nowPlaying != null -> showPlayer = true
                }
            }
            val activateMantelItem: () -> Unit = {
                when {
                    lastOpenedIsActiveAudio || (mantelBook == null && nowPlaying != null) -> vm.togglePlayPause()
                    mantelBook != null -> playBook(mantelBook)
                }
            }
            val mantelDisplayBook = if (!readingEnabled && mantelBook?.mediaType == AppMediaType.EBOOK) {
                mantelBook.copy(mediaType = AppMediaType.AUDIOBOOK)
            } else {
                mantelBook
            }
            val selectBook: (Book) -> Unit = {
                if (it.mediaType == AppMediaType.PODCAST && it.episodeId != null) episodeBook = it
                else detailBook = it
            }
            val jumpToAnnotation: (Book, ReaderAnnotation) -> Unit = { book, annotation ->
                if (annotation.opensInPlayer) {
                    pendingPlayerBookId = book.id
                    vm.openAudioAt(book, annotation.audioPositionMs ?: 0L)
                    showPlayer = true
                } else {
                    onOpenAnnotation(book, annotation)
                    if (!detailInPane) detailBook = null
                }
            }
            val detailContent: @Composable (Book) -> Unit = { b ->
                if (b.isPodcastShow) {
                    PodcastShowScreen(
                        initial = b,
                        onBack = {
                            detailBook = null
                            pendingPlayerBookId = null
                        },
                        onPlay = {
                            pendingPlayerBookId = it.id
                            vm.openAudio(it)
                            showPlayer = true
                        },
                        onOpenEpisode = { episodeBook = it },
                    )
                } else {
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
                        onRead = {
                            onOpenEbook(it)
                            if (!detailInPane) detailBook = null
                        },
                        onOpenBook = { detailBook = it },
                        onAskLibrarian = onAskLibrarian,
                        onOpenAnnotation = jumpToAnnotation,
                        onStartClub = if (clubs?.available == true) ({ book ->
                            clubBook = book
                            showClubs = true
                        }) else null,
                    )
                }
            }
            val paneBook = detailBook
            val paneDetail: (@Composable () -> Unit)? = if (paneBook == null) null else { { detailContent(paneBook) } }

            val einkOn = einkState.active
            val view = androidx.compose.ui.platform.LocalView.current
            LaunchedEffect(
                tab,
                showPlayer,
                detailBook != null,
                episodeBook != null,
                showSettings,
                showCompletionCenter,
                showInsights,
                showRecaps,
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
                        onOpenProfiles = onOpenProfiles,
                        profileName = profileName,
                        isPlaying = transport.isPlaying && lastOpenedIsActiveAudio,
                        onSelectBook = selectBook,
                        onPlayBook = playBook,
                        onListenBook = listenBook,
                        onReadBook = onOpenEbook,
                        onOpenSettings = { showSettings = true },
                        onAddSource = onManageSources,
                        onOpenPodcasts = { tab = HearthTab.PODCASTS },
                        onOpenHardcover = { onOpenSettingsDestination(HearthSettingsDestination.Hardcover) },
                    )
                    HearthTab.LIBRARY -> HearthListDetail(
                        listWidth = listPaneWidth,
                        detail = paneDetail.takeIf { bookOrbitTool == null },
                    ) {
                        HearthLibraryScreen(
                            covered = overlayVisible,
                            onSelectBook = selectBook,
                            onPlayBook = playBook,
                            onListenBook = listenBook,
                            onPlaybackStarted = { showPlayer = true },
                            onAddSource = onManageSources,
                            onOpenSettings = { showSettings = true },
                            onOpenBookOrbitTool = { tool -> openBookOrbitTool(tool, null) },
                            onOpenClubs = if (clubs?.available == true) ({ showClubs = true }) else null,
                        )
                    }
                    HearthTab.PODCASTS -> PodcastsScreen(
                        onOpenShow = selectBook,
                        onOpenEpisode = { episodeBook = it },
                        onPlay = listenBook,
                    )
                    HearthTab.JOURNAL -> HearthJournalScreen(
                        onSelectBook = selectBook,
                        onOpenCompletions = { showCompletionCenter = true },
                        onOpenInsights = { showInsights = true },
                        onOpenRecaps = { showRecaps = true },
                        onOpenStatsHub = { showStatsHub = true },
                        onOpenSleep = { showSleepInsights = true },
                        onOpenSettings = { showSettings = true },
                    )
                }
                Column(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .onSizeChanged { mantelBarHeightPx = it.height },
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    DownloadProgressPill(
                        transfers = activeDownloads,
                        onOpen = { onOpenSettingsDestination(HearthSettingsDestination.Downloads) },
                        modifier = Modifier.padding(horizontal = Hearth.Spacing.L),
                    )
                    MantelBar(
                        selected = tab,
                        onSelect = {
                            if (detailInPane) detailBook = null
                            tab = it
                        },
                        lastOpenedBook = mantelDisplayBook,
                        nowPlaying = nowPlaying,
                        transport = transport,
                        subtitle = currentChapter,
                        onOpenItem = openMantelItem,
                        onItemAction = activateMantelItem,
                        showItemShortcut = showDockBookShortcut,
                    )
                }

                AnimatedVisibility(
                    visible = showInsights,
                    enter = enterT,
                    exit = exitT,
                ) {
                    HearthInsightsScreen(
                        onBack = { showInsights = false },
                        onOpenRecaps = { showInsights = false; showRecaps = true },
                        onSelectBook = {
                            showInsights = false
                            detailBook = it
                        },
                    )
                }

                AnimatedVisibility(
                    visible = showRecaps,
                    enter = enterT,
                    exit = exitT,
                ) {
                    HearthReadingRecapScreen(
                        onBack = { showRecaps = false },
                        onSelectBook = {
                            showRecaps = false
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
                        onOpenBookOrbit = { openBookOrbitTool(BookOrbitTool.INSIGHTS, null) },
                    )
                }

                AnimatedVisibility(
                    visible = showSleepInsights,
                    enter = enterT,
                    exit = exitT,
                ) {
                    HearthSleepInsightsScreen(onBack = { showSleepInsights = false })
                }

                BookOrbitTool.entries.forEach { tool ->
                    AnimatedVisibility(
                        visible = bookOrbitTool == tool,
                        enter = enterT,
                        exit = exitT,
                    ) {
                        val close = { bookOrbitTool = null }
                        val openFromTool: (Book) -> Unit = {
                            bookOrbitTool = null
                            detailBook = it
                        }
                        when (tool) {
                            BookOrbitTool.INSIGHTS -> BookOrbitInsightsScreen(onBack = close, onOpenBook = openFromTool)
                            BookOrbitTool.ACHIEVEMENTS -> BookOrbitAchievementsScreen(
                                onBack = close,
                                initialAccountId = bookOrbitAccountId,
                            )
                            BookOrbitTool.HIGHLIGHTS -> BookOrbitHighlightsScreen(
                                onBack = close,
                                onOpenBook = openFromTool,
                                initialAccountId = bookOrbitAccountId,
                            )
                            BookOrbitTool.BOOK_DROP -> BookOrbitBookDropScreen(
                                initialAccountId = bookOrbitAccountId,
                                onBack = close,
                            )
                            BookOrbitTool.SMART_SCOPES -> HearthListDetail(
                                listWidth = listPaneWidth,
                                detail = paneDetail,
                            ) {
                                BookOrbitSmartScopesScreen(
                                    initialAccountId = bookOrbitAccountId,
                                    selectedBookKey = detailBook?.uniqueKey.takeIf { listPaneWidth != null },
                                    onBack = {
                                        if (listPaneWidth != null) detailBook = null
                                        bookOrbitTool = null
                                    },
                                    onOpenBook = { detailBook = it },
                                )
                            }
                        }
                    }
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
                    visible = detailBook != null && !detailInPane,
                    enter = enterT,
                    exit = exitT,
                ) {
                    detailBook?.let { b -> detailContent(b) }
                }

                AnimatedVisibility(
                    visible = episodeBook != null,
                    enter = enterT,
                    exit = exitT,
                ) {
                    episodeBook?.let { episode ->
                        PodcastEpisodeScreen(
                            episode = episode,
                            onBack = { episodeBook = null },
                            onPlay = listenBook,
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
                        onOpdsAuthorize = onOpdsAuthorize,
                        onOpenBookOrbitTool = openBookOrbitTool,
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

                if (showClubs && clubs?.available == true && clubBooks != null) {
                    com.enve.hearth.clubs.BookClubsScreen(
                        clubs = clubs, inventory = clubBooks, invitation = clubCode, firstBook = clubBook,
                        onClose = closeClubs,
                        onFindPassage = { book, query ->
                            closeClubs()
                            onOpenEbookPassage(book, query)
                        },
                        onOpenBook = { book, position ->
                            closeClubs()
                            if (book.mediaType == AppMediaType.EBOOK) onOpenEbook(book)
                            else {
                                pendingPlayerBookId = book.id
                                if (position == null) vm.openAudio(book) else vm.openAudioAt(book, position)
                                showPlayer = true
                            }
                        },
                    )
                }

                positionLink?.let { message ->
                    key(message) { ListeningPositionScanScreen(initialMessage = message) { positionLink = null } }
                }

                playerOverlay()

                val playbackNotice by vm.playbackNotice.collectAsStateWithLifecycle()
                val startingBook by vm.startingBook.collectAsStateWithLifecycle()
                val startingTitle = startingBook?.takeIf { nowPlaying?.bookKey != it.uniqueKey }?.title
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
                if (playbackNotice == null && startingTitle != null) {
                    NoticeCapsule(
                        "Starting $startingTitle…",
                        Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = LocalMantelInset.current + Hearth.Spacing.S),
                        busy = true,
                    )
                }
            }
        }
    }
}

private fun HearthStartTab.toHearthTab(): HearthTab = when (this) {
    HearthStartTab.HEARTH -> HearthTab.HEARTH
    HearthStartTab.LIBRARY -> HearthTab.LIBRARY
    HearthStartTab.PODCASTS -> HearthTab.PODCASTS
    HearthStartTab.JOURNAL -> HearthTab.JOURNAL
}

@Composable
private fun NoticeCapsule(text: String, modifier: Modifier = Modifier, busy: Boolean = false) {
    val palette = Hearth.palette
    val shape = if (Hearth.eink.sharpCorners) RectangleShape else RoundedCornerShape(999.dp)
    Row(
        modifier
            .padding(horizontal = 32.dp)
            .clip(shape)
            .background(palette.bgElevated)
            .border(0.5.dp, palette.hairline, shape)
            .padding(horizontal = 18.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (busy && !Hearth.eink.suppressAnimations) {
            CircularProgressIndicator(Modifier.size(14.dp), color = palette.ember, strokeWidth = 2.dp)
            Spacer(Modifier.width(Hearth.Spacing.S))
        }
        Text(text, style = HearthText.Caption, color = palette.text)
    }
}
