package com.enve.app.ui.screens

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.material.icons.filled.BrightnessMedium
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SwipeRight
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import coil.imageLoader
import coil.request.ImageRequest
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.engine.prefs.ReadNextPosition
import com.enve.core.data.local.LastOpenedBookStore
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.viewmodel.ComicBackgroundTheme
import com.enve.app.viewmodel.ComicPageFit
import com.enve.app.viewmodel.ComicProgressionMode
import com.enve.app.viewmodel.ComicReaderArgs
import com.enve.app.viewmodel.ComicReaderSettings
import com.enve.app.viewmodel.ComicReaderUiState
import com.enve.app.viewmodel.ComicReaderViewModel
import com.enve.app.viewmodel.ComicReadingDirection
import com.enve.app.viewmodel.ComicSpreadMode
import com.enve.app.viewmodel.ThemeViewModel
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material.icons.filled.Check
import androidx.compose.ui.graphics.Brush

@AndroidEntryPoint
class ComicReaderActivity : ComponentActivity() {

    private val vm: ComicReaderViewModel by viewModels()
    private val themeViewModel: ThemeViewModel by viewModels()
    private lateinit var insetsController: WindowInsetsControllerCompat

    @javax.inject.Inject lateinit var epdRefreshManager: com.enve.app.eink.EpdRefreshManager
    @javax.inject.Inject lateinit var audioPlaybackManager: com.enve.app.playback.AudioPlaybackManager
    @javax.inject.Inject lateinit var lastOpenedBookStore: LastOpenedBookStore
    @javax.inject.Inject lateinit var hearthPreferences: com.enve.engine.prefs.PreferencesFacade

    fun refreshEinkAfterPageTurn() {
        if (themeViewModel.themeState.value.einkProfile.active) {
            epdRefreshManager.requestPageTurnRefresh(window.decorView, isFullPageBoundary = true)
        }
    }

    companion object {
        private const val EXTRA_BOOK_ID = "bookId"
        private const val EXTRA_BOOK_SOURCE = "bookSource"
        private const val EXTRA_CONNECTION_ID = "connectionId"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_AUTHOR = "author"
        private const val EXTRA_FORMAT = "format"
        private const val EXTRA_LOCATOR = "locator"
        const val EXTRA_HEARTH_CHROME = "hearthChrome"

        fun createIntent(
            context: Context,
            bookId: String,
            bookSource: BookSource,
            connectionId: String? = null,
            title: String,
            author: String,
            format: String?,
            locator: String?,
        ): Intent = Intent(context, ComicReaderActivity::class.java).apply {
            putExtra(EXTRA_BOOK_ID, bookId)
            putExtra(EXTRA_BOOK_SOURCE, bookSource.name)
            if (connectionId != null) {
                putExtra(EXTRA_CONNECTION_ID, connectionId)
            }
            putExtra(EXTRA_TITLE, title)
            putExtra(EXTRA_AUTHOR, author)
            if (format != null) putExtra(EXTRA_FORMAT, format)
            if (locator != null) putExtra(EXTRA_LOCATOR, locator)
        }
    }

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = android.graphics.Color.BLACK
        window.navigationBarColor = android.graphics.Color.BLACK
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        insetsController = WindowInsetsControllerCompat(window, window.decorView)
        insetsController.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE

        val bookId = intent.getStringExtra(EXTRA_BOOK_ID) ?: run {
            finish()
            return
        }
        val bookSource = intent.getStringExtra(EXTRA_BOOK_SOURCE)
            ?.let { runCatching { BookSource.valueOf(it) }.getOrNull() }
            ?: BookSource.GRIMMORY
        val connectionId = intent.getStringExtra(EXTRA_CONNECTION_ID)
        if (savedInstanceState == null) {
            lifecycleScope.launch { lastOpenedBookStore.record(bookId, bookSource, connectionId) }
        }
        val format = ReaderFormat.fromServerType(intent.getStringExtra(EXTRA_FORMAT))
            .takeIf { it.isComic }
            ?: ReaderFormat.CBZ

        vm.initialize(
            ComicReaderArgs(
                bookId = bookId,
                bookSource = bookSource,
                connectionId = connectionId,
                title = intent.getStringExtra(EXTRA_TITLE).orEmpty(),
                author = intent.getStringExtra(EXTRA_AUTHOR).orEmpty(),
                format = format,
                locator = intent.getStringExtra(EXTRA_LOCATOR),
            ),
        )

        setContent {
            val state by vm.state.collectAsStateWithLifecycle()
            val themeState by themeViewModel.themeState.collectAsStateWithLifecycle()
            val uiTextScale by hearthPreferences.uiTextScale.collectAsStateWithLifecycle(initialValue = 1f)
            val readNextEnabled by hearthPreferences.readNextEnabled.collectAsStateWithLifecycle(initialValue = true)
            val readNextPosition by hearthPreferences.readNextPosition.collectAsStateWithLifecycle(
                initialValue = ReadNextPosition.BOTTOM,
            )
            val useHearthChrome = remember { intent.getBooleanExtra(EXTRA_HEARTH_CHROME, false) }

            val chromeVisible = (state.pages.isEmpty()) || (state.error != null) || state.showSettingsSheet

            LaunchedEffect(chromeVisible) {
                if (chromeVisible) {
                    insetsController.show(WindowInsetsCompat.Type.systemBars())
                } else {
                    insetsController.hide(WindowInsetsCompat.Type.systemBars())
                }
            }

            LaunchedEffect(state.settings.brightness) {
                val lp = window.attributes
                lp.screenBrightness = if (state.settings.brightness < 0f) {
                    WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                } else {
                    state.settings.brightness.coerceIn(0.05f, 1f)
                }
                window.attributes = lp
            }

            com.enve.hearth.design.HearthUiTextScale(uiTextScale) {
                EnveTheme(
                    appTheme = themeState.effectiveAppTheme,
                    themeColor = themeState.themeColor,
                    dynamicBackgroundEnabled = themeState.dynamicBackgroundEnabled,
                    einkProfile = themeState.einkProfile,
                ) {
                    ComicReaderScreen(
                        state = state,
                        hearthChrome = useHearthChrome,
                        readNextEnabled = readNextEnabled,
                        readNextPosition = readNextPosition,
                        onSettingsChange = vm::updateSettings,
                        onBack = { finish() },
                        onPageChange = vm::showPage,
                        onPagesNeeded = vm::requestPages,
                        onToggleBookmark = vm::toggleBookmark,
                        onOpenSettings = vm::openSettingsSheet,
                        onCloseSettings = vm::closeSettingsSheet,
                        onOpenNextInSeries = { next ->
                            startActivity(readerIntentForBook(next, hearthChrome = useHearthChrome))
                            finish()
                        },
                    )
                }
            }
        }
    }

    override fun onPause() {
        super.onPause()
        vm.syncProgress()
    }

    override fun onDestroy() {
        if (isFinishing) vm.endStreamingSession()
        super.onDestroy()
    }

    @SuppressLint("RestrictedApi")
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val audioActive = audioPlaybackManager.state.value.isPlaying
        val volumeNav = vm.state.value.settings.volumeButtonNavigation
        val direction = ReaderHardwareKeyPolicy.directionFor(
            keyCode = event.keyCode,
            volumeButtonNavigation = volumeNav,
            audioActive = audioActive,
        )
        if (direction != null) {
            val state = vm.state.value
            if (state.pages.isNotEmpty() && ReaderHardwareKeyPolicy.shouldTriggerTurn(event.action, event.repeatCount)) {
                val isRtl = state.settings.readingDirection == ComicReadingDirection.RIGHT_TO_LEFT
                val offset = if (direction == ReaderPageKeyDirection.FORWARD) 1 else -1
                vm.showPage(state.currentPage + if (isRtl) -offset else offset)
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }

}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ComicReaderScreen(
    state: ComicReaderUiState,
    hearthChrome: Boolean,
    readNextEnabled: Boolean,
    readNextPosition: ReadNextPosition,
    onSettingsChange: (ComicReaderSettings) -> Unit,
    onBack: () -> Unit,
    onPageChange: (Int) -> Unit,
    onPagesNeeded: (List<Int>) -> Unit,
    onToggleBookmark: (Int) -> Unit,
    onOpenSettings: () -> Unit,
    onCloseSettings: () -> Unit,
    onOpenNextInSeries: (com.enve.core.data.model.Book) -> Unit = {},
) {
    val baseSettings = state.settings

    val settings = if (com.enve.app.ui.theme.EnveTheme.isEink) {
        baseSettings.copy(
            progressionMode = ComicProgressionMode.PAGED,
            zoomEnabled = false,
            backgroundTheme = ComicBackgroundTheme.WHITE,
        )
    } else {
        baseSettings
    }
    val bgColor = Color(settings.backgroundTheme.argb)
    val configuration = LocalConfiguration.current
    val isLandscape = configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
    val spreadActive = state.pages.size > 1 &&
        settings.progressionMode == ComicProgressionMode.PAGED &&
        settings.spreadMode != ComicSpreadMode.OFF &&
        (settings.spreadMode == ComicSpreadMode.ON || isLandscape)
    val pageEntries = remember(state.pages, spreadActive) {
        buildPageEntries(state.pages.size, spreadActive)
    }
    val currentEntryIndex = remember(state.currentPage, pageEntries) {
        pageEntries.indexOfFirst { state.currentPage in it }.coerceAtLeast(0)
    }
    val currentEntry = pageEntries.getOrElse(currentEntryIndex) {
        listOf(state.currentPage.coerceIn(0, state.pages.lastIndex.coerceAtLeast(0)))
    }

    var showChrome by remember { mutableStateOf(value = true) }

    LaunchedEffect(showChrome, state.pages.size, settings.autoHideChrome, settings.progressionMode) {
        if (
            showChrome &&
            settings.autoHideChrome &&
            state.pages.isNotEmpty() &&
            settings.progressionMode == ComicProgressionMode.PAGED
        ) {
            kotlinx.coroutines.delay(3_000)
            showChrome = false
        }
    }

    fun nextPage() {
        val nextEntry = pageEntries.getOrNull(currentEntryIndex + 1) ?: return
        onPageChange(nextEntry.first())
    }

    fun previousPage() {
        val previousEntry = pageEntries.getOrNull(currentEntryIndex - 1) ?: return
        onPageChange(previousEntry.first())
    }

    val chromeVisible = showChrome || state.pages.isEmpty() || state.error != null

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(bgColor),
    ) {

        when {
            state.error != null -> {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        text = state.error,
                        color = Color.White,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(24.dp),
                    )
                }
            }
            state.pages.isNotEmpty() && settings.progressionMode == ComicProgressionMode.VERTICAL_STRIP -> {
                ComicVerticalStrip(
                    pages = state.pages,
                    availablePages = state.availablePages,
                    currentPage = state.currentPage,
                    fit = settings.pageFit,
                    bgColor = bgColor,
                    onPageVisible = onPageChange,
                    onToggleChrome = { showChrome = !showChrome },
                    onPagesNeeded = onPagesNeeded,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            state.pages.isNotEmpty() -> {
                ComicHorizontalPager(
                    pages = state.pages,
                    availablePages = state.availablePages,
                    currentPage = state.currentPage,
                    spreadActive = spreadActive,
                    settings = settings,
                    bgColor = bgColor,
                    onPageChange = onPageChange,
                    onPrevious = ::previousPage,
                    onNext = ::nextPage,
                    onToggleChrome = { showChrome = !showChrome },
                    onPagesNeeded = onPagesNeeded,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            else -> {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
                        Spacer(Modifier.height(16.dp))
                        Text(state.loadingText, color = Color.White.copy(alpha = 0.9f))
                        if (state.loadingProgress != null) {
                            Spacer(Modifier.height(8.dp))
                            Text("${state.loadingProgress}%", color = Color.White.copy(alpha = 0.55f), fontSize = 13.sp)
                        }
                    }
                }
            }
        }

        if (hearthChrome) {
            com.enve.app.ui.screens.reader.HearthComicChrome(
                state = state,
                baseSettings = baseSettings,
                visiblePageIndices = currentEntry,
                chromeVisible = chromeVisible,
                einkActive = com.enve.app.ui.theme.EnveTheme.isEink,
                onBack = onBack,
                onToggleBookmark = { onToggleBookmark(state.currentPage) },
                onOpenSettings = onOpenSettings,
                onCloseSettings = onCloseSettings,
                onSettingsChange = onSettingsChange,
                onPageChange = onPageChange,
            )
        } else {
            AnimatedVisibility(
                visible = chromeVisible,
                enter = fadeIn(tween(200)) + slideInVertically(tween(200)) { -it / 2 },
                exit = fadeOut(tween(300)) + slideOutVertically(tween(300)) { -it / 2 },
                modifier = Modifier.align(Alignment.TopCenter).fillMaxWidth(),
            ) {
                ComicTopBar(
                    title = state.title,
                    author = state.author,
                    formatLabel = state.formatLabel,
                    isBookmarked = state.currentPage in state.bookmarks,
                    onBack = onBack,
                    onToggleBookmark = { onToggleBookmark(state.currentPage) },
                    onOpenSettings = onOpenSettings,
                )
            }

            AnimatedVisibility(
                visible = chromeVisible && state.pages.isNotEmpty(),
                enter = fadeIn(tween(200)) + slideInVertically(tween(200)) { it / 2 },
                exit = fadeOut(tween(300)) + slideOutVertically(tween(300)) { it / 2 },
                modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth(),
            ) {
                ComicBottomBar(
                    state = state,
                    visiblePageIndices = currentEntry,
                    onPrevious = ::previousPage,
                    onNext = ::nextPage,
                    onPageChange = onPageChange,
                    isRtl = state.settings.readingDirection == ComicReadingDirection.RIGHT_TO_LEFT,
                )
            }
        }

        val nextBook = state.nextInSeries
        val onLastPage = state.pages.isNotEmpty() && state.currentPage >= state.pages.lastIndex
        if (readNextEnabled && nextBook != null && onLastPage) {
            NextInSeriesButton(
                book = nextBook,
                onClick = { onOpenNextInSeries(nextBook) },
                modifier = Modifier
                    .align(
                        if (readNextPosition == ReadNextPosition.TOP) {
                            Alignment.TopCenter
                        } else {
                            Alignment.BottomCenter
                        },
                    )
                    .padding(
                        top = if (readNextPosition == ReadNextPosition.TOP) 96.dp else 0.dp,
                        bottom = if (readNextPosition == ReadNextPosition.BOTTOM) 96.dp else 0.dp,
                        start = 24.dp,
                        end = 24.dp,
                    ),
            )
        }

        if (state.showSettingsSheet && !hearthChrome) {
            ComicSettingsSheet(
                settings = baseSettings,
                onSettingsChange = onSettingsChange,
                onDismiss = onCloseSettings,
            )
        }
    }
}

internal fun pageLabel(indices: List<Int>, total: Int): String {
    if (indices.isEmpty()) return "…"
    val nums = indices.asSequence().map { it + 1 }.sorted().toList()
    return if (nums.size == 1) "Page ${nums.first()} of $total" else "Pages ${nums.first()}-${nums.last()} of $total"
}
