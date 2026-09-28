package com.enve.app.ui.screens

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.drawable.ColorDrawable
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Bundle
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.webkit.WebSettings
import android.webkit.WebView
import android.widget.FrameLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.animation.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.text.font.FontWeight
import kotlin.math.roundToInt
import androidx.core.graphics.Insets
import androidx.core.text.HtmlCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.commitNow
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import com.enve.app.EnveApplication
import com.enve.app.R
import com.enve.core.data.local.LastOpenedBookStore
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.*
import com.enve.app.data.reader.*
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.app.data.repository.CustomFontRepository
import com.enve.app.document.EbookNormalizationException
import com.enve.app.document.EbookSourceFormat
import com.enve.app.document.NativeKindleEpubConverter
import com.enve.app.document.OnDeviceEbookNormalizer
import com.enve.app.eink.EpdRefreshManager
import com.enve.app.readium.MediaOverlayEngine
import com.enve.app.readium.MediaOverlayTextProgression
import com.enve.app.readium.SmilClip
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.screens.reader.BUNDLED_READER_FONTS
import com.enve.app.ui.screens.reader.FoliateReaderEngine
import com.enve.app.viewmodel.ReaderViewModel
import com.enve.app.viewmodel.ThemeViewModel
import com.enve.app.viewmodel.CachedReaderProgress
import com.enve.app.viewmodel.FoliateOpenPlan
import com.enve.app.viewmodel.OpenProgressAuthority
import com.enve.app.viewmodel.OpenRemoteProgress
import com.enve.core.data.provider.ProviderEbookResource
import com.enve.core.data.sync.AudioLocatorPosition
import com.enve.core.data.sync.ProgressConflictPassage
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import com.enve.core.reader.ReaderEnginePolicy
import com.enve.core.reader.ReaderEngineRequest
import com.enve.engine.prefs.ReadNextPosition
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import org.readium.r2.navigator.HyperlinkNavigator
import org.readium.r2.navigator.epub.EpubNavigatorFactory
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.services.positionsByReadingOrder
import org.readium.r2.shared.util.AbsoluteUrl
import org.readium.r2.shared.util.Error as ReadiumError
import org.readium.r2.shared.util.Url
import org.readium.r2.shared.util.data.CompositeContainer
import org.readium.r2.shared.util.getOrElse
import org.readium.r2.shared.util.mediatype.MediaType
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.Locale
import java.util.zip.ZipFile
import kotlin.math.roundToLong
import javax.inject.Inject

internal data class OpenProgressResolution(
    val locatorJson: String?,
    val progress: Float,
    val mayUseCachedAudioPosition: Boolean,
)

internal data class OpenProgressPlan(
    val resolution: OpenProgressResolution,
    val remote: OpenRemoteProgress,
)

private sealed interface RemoteProgressOutcome {
    data class Resolved(val plan: OpenProgressPlan) : RemoteProgressOutcome
    data class NeedsChoice(
        val conflict: com.enve.app.data.sync.SyncCoordinator.OpenSyncResult.Conflict,
        val snapshot: SyncSnapshot?,
        val localLocatorJson: String?,
        val localProgress: Float,
    ) : RemoteProgressOutcome
}

internal fun openProgressResolutionFor(
    authority: OpenProgressAuthority,
    localLocatorJson: String?,
    localProgress: Float,
    remoteLocatorJson: String?,
    remoteProgress: Float,
): OpenProgressResolution = when (authority) {
    OpenProgressAuthority.REMOTE ->
        OpenProgressResolution(remoteLocatorJson, remoteProgress, mayUseCachedAudioPosition = false)
    OpenProgressAuthority.AUTOMATIC, OpenProgressAuthority.LOCAL ->
        OpenProgressResolution(localLocatorJson, localProgress, mayUseCachedAudioPosition = true)
}

internal suspend fun awaitWithinActiveBudget(
    budgetMs: Long,
    pausedMs: () -> Long,
    await: suspend (Long) -> Boolean,
): Boolean {
    var remaining = budgetMs
    var credited = 0L
    while (true) {
        if (await(remaining)) return true
        val paused = pausedMs()
        val uncredited = paused - credited
        if (uncredited <= 0L) return false
        credited = paused
        remaining = uncredited
    }
}

internal fun selectAudioResumeSeconds(
    locatorAudioSeconds: Long?,
    cachedAudioSeconds: Long?,
    mayUseCachedAudioPosition: Boolean,
): Long? = locatorAudioSeconds
    ?: cachedAudioSeconds?.takeIf { mayUseCachedAudioPosition && it > 0L }

internal fun shouldUseReaderNetwork(
    hasOfflineSource: Boolean,
    networkAvailable: Boolean,
): Boolean = networkAvailable && !hasOfflineSource

@AndroidEntryPoint
@OptIn(FlowPreview::class, ExperimentalReadiumApi::class)
class EbookReaderActivity : FragmentActivity() {

    @Inject lateinit var prefs: PreferencesManager
    @Inject lateinit var okHttpClient: OkHttpClient
    @Inject lateinit var repository: GrimmoryRepository
    @Inject lateinit var syncCoordinator: com.enve.app.data.sync.SyncCoordinator
    @Inject lateinit var progressConflictPassages: com.enve.app.data.sync.ProgressConflictPassageService
    @Inject lateinit var epdRefreshManager: EpdRefreshManager
    @Inject lateinit var einkManager: com.enve.app.eink.EinkManager
    @Inject lateinit var audioPlaybackManager: com.enve.app.playback.AudioPlaybackManager
    @Inject lateinit var comicOfflineStorage: com.enve.app.data.offline.ComicOfflineStorage
    @Inject lateinit var customFontRepository: com.enve.app.data.repository.CustomFontRepository
    @Inject lateinit var hearthPreferences: com.enve.engine.prefs.PreferencesFacade
    @Inject lateinit var lastOpenedBookStore: LastOpenedBookStore

    private val vm: ReaderViewModel by viewModels()
    private val themeViewModel: ThemeViewModel by viewModels()

    private lateinit var loadingRoot: View
    private lateinit var loadingText: TextView
    private lateinit var loadingBar: ProgressBar
    private lateinit var loadingPct: TextView
    private lateinit var epubContainer: FrameLayout
    private lateinit var composeOverlay: ComposeView
    private var epubContainerSafeInsets: Insets = Insets.NONE
    private var verticalReadingPaddingPx = 0
    private var readiumFootnoteDialog: android.app.AlertDialog? = null
    private var readiumNavigator: EpubNavigatorFragment? = null
    private var readiumFootnoteReturnLocator: Locator? = null

    private var bookId: String = ""
    private var bookSource: BookSource = BookSource.GRIMMORY
    private var bookConnectionId: String? = null
    private var bookTitle: String = ""
    private var bookAuthor: String = ""
    private var bookLastReadTime: Long = 0L
    private var requestedReaderEngine by mutableStateOf(ReaderEngineKind.READIUM)
    private var foliateEngine: FoliateReaderEngine? = null
    private var foliateReady = false
    private var foliateFallbackStarted = false
    private var openProgressPlan: OpenProgressPlan? = null
    private var userDecisionStartedAtMs = 0L
    private var userDecisionTotalMs = 0L

    private var ttsEngine: TextToSpeech? = null

    private var selectionCallback: ReaderSelectionCallback? = null
    private var edgeBrightnessGesture = false
    private var edgeBrightnessConsumed = false
    private var edgeBrightnessLevel = 1f
    private var edgeBrightnessLastApplied = 1f
    private var documentGestureSequenceBlocked = false

    private val gestureDetector by lazy {
        GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean {
                val prefs = vm.state.value.prefs
                edgeBrightnessGesture = prefs.edgeBrightnessSwipe && e.x <= window.decorView.width * 0.12f
                edgeBrightnessConsumed = false
                edgeBrightnessLevel = prefs.screenBrightness.takeIf { it >= 0f } ?: 1f
                edgeBrightnessLastApplied = edgeBrightnessLevel
                return true
            }

            override fun onScroll(
                e1: MotionEvent?,
                e2: MotionEvent,
                distanceX: Float,
                distanceY: Float,
            ): Boolean {
                if (!edgeBrightnessGesture || e1 == null) return false
                val totalX = e2.x - e1.x
                val totalY = e2.y - e1.y
                if (!edgeBrightnessConsumed) {
                    val threshold = 12f * resources.displayMetrics.density
                    if (kotlin.math.abs(totalY) < threshold || kotlin.math.abs(totalY) <= kotlin.math.abs(totalX)) return false
                    edgeBrightnessConsumed = true
                }
                val height = window.decorView.height.coerceAtLeast(1).toFloat()
                edgeBrightnessLevel = (edgeBrightnessLevel + distanceY / height).coerceIn(0.05f, 1f)
                if (kotlin.math.abs(edgeBrightnessLevel - edgeBrightnessLastApplied) >= 0.025f) {
                    edgeBrightnessLastApplied = edgeBrightnessLevel
                    vm.updatePreferences(vm.state.value.prefs.copy(screenBrightness = edgeBrightnessLevel))
                }
                return true
            }

            override fun onDoubleTap(e: MotionEvent): Boolean {
                val st = vm.state.value
                if (!st.readAlongSupported) return false
                if (st.showAppearanceSheet || st.showTocSheet || st.showAnnotationDialog) return false

                val webView = findWebViewUnderTouch(e.rawX, e.rawY, epubContainer) ?: return false
                val webLocation = IntArray(2)
                webView.getLocationOnScreen(webLocation)
                val density = resources.displayMetrics.density
                val cssX = (e.rawX - webLocation[0]) / density
                val cssY = (e.rawY - webLocation[1]) / density

                vm.handleReadAlongDoubleTap(cssX, cssY)
                return true
            }

            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                val st = vm.state.value
                if (st.showAppearanceSheet || st.showTocSheet ||
                    st.showAnnotationDialog || st.showMoreMenu || st.showSearchSheet) return false

                val w = window.decorView.width.toFloat()
                val h = window.decorView.height.toFloat()
                if (st.showChrome && (e.y < h * 0.12f || e.y > h * 0.88f)) return false
                when (ReaderTapZones.zoneAt(e.x, w, st.prefs.tapZoneWidth)) {
                    ReaderTapZone.LEFT_EDGE -> turnPageBackward()
                    ReaderTapZone.RIGHT_EDGE -> turnPageForward()
                    ReaderTapZone.CENTER -> vm.toggleChrome()
                }
                return true
            }
        })
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
            readiumNavigator?.currentLocator?.value?.let {
                readiumFootnoteReturnLocator = it
            }
            val state = vm.state.value
            documentGestureSequenceBlocked = state.showAppearanceSheet || state.showTocSheet ||
                state.showSearchSheet || state.showMoreMenu || state.showAnnotationDialog ||
                state.showReadAloudSheet || state.showSelectionPopup || state.showAutoScrollPanel ||
                state.showToolbarCustomizer || state.showAnnotationsSheet ||
                state.activeDecorationAnnotation != null || state.pendingProgressConflict != null
        }
        if (!documentGestureSequenceBlocked) gestureDetector.onTouchEvent(ev)

        val sequenceEnded = ev.actionMasked == MotionEvent.ACTION_UP || ev.actionMasked == MotionEvent.ACTION_CANCEL
        if (sequenceEnded) {
            selectionCallback?.notifyFingerUp()
            if (!documentGestureSequenceBlocked && ev.actionMasked == MotionEvent.ACTION_UP) {
                vm.noteReadiumUserInteraction()
            }
        }
        val consumed = edgeBrightnessConsumed
        if (sequenceEnded) {
            if (consumed && kotlin.math.abs(edgeBrightnessLevel - edgeBrightnessLastApplied) > 0.001f) {
                vm.updatePreferences(vm.state.value.prefs.copy(screenBrightness = edgeBrightnessLevel))
            }
            edgeBrightnessGesture = false
            edgeBrightnessConsumed = false
            documentGestureSequenceBlocked = false
        }
        if (consumed) return true
        return super.dispatchTouchEvent(ev)
    }

    override fun onActionModeStarted(mode: android.view.ActionMode) {
        super.onActionModeStarted(mode)
        mode.menu.clear()
    }

    @SuppressLint("RestrictedApi")
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val volumeNav = vm.state.value.prefs.volumeButtonNavigation
        val audioActive = vm.state.value.readAlongPlaying ||
            audioPlaybackManager.state.value.isPlaying
        val direction = ReaderHardwareKeyPolicy.directionFor(
            keyCode = event.keyCode,
            volumeButtonNavigation = volumeNav,
            audioActive = audioActive,
        )

        if (direction != null) {
            if (ReaderHardwareKeyPolicy.shouldTriggerTurn(event.action, event.repeatCount)) {
                when (direction) {
                    ReaderPageKeyDirection.FORWARD -> turnPageForward()
                    ReaderPageKeyDirection.BACKWARD -> turnPageBackward()
                }
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    private fun turnPageForward() {
        vm.pageForward()
    }

    private fun turnPageBackward() {
        vm.pageBackward()
    }

    private fun refreshEinkOnChapterBoundary() {
        if (themeViewModel.themeState.value.einkProfile.active) {
            epdRefreshManager.requestPageTurnRefresh(window.decorView, isFullPageBoundary = true)
        }
    }

    private fun applySoftwareLayerToWebViews(root: View) {
        if (root is WebView) {
            root.setLayerType(View.LAYER_TYPE_SOFTWARE, null)
            return
        }
        if (root is android.view.ViewGroup) {
            for (i in 0 until root.childCount) {
                applySoftwareLayerToWebViews(root.getChildAt(i))
            }
        }
    }

    private fun findWebViewUnderTouch(rawX: Float, rawY: Float, root: View): WebView? {
        if (root is WebView && root.isShown) {
            val loc = IntArray(2)
            root.getLocationOnScreen(loc)
            val xi = rawX.toInt()
            val yi = rawY.toInt()
            if (xi in loc[0]..(loc[0] + root.width) && yi in loc[1]..(loc[1] + root.height)) {
                return root
            }
        }
        if (root is android.view.ViewGroup) {
            for (i in 0 until root.childCount) {
                findWebViewUnderTouch(rawX, rawY, root.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    private fun prepareReadiumWebViews(root: View) {
        if (root is WebView) {
            disableWebViewDarkening(root)
            injectMediaColorReset(root)
            return
        }
        if (root is android.view.ViewGroup) {
            for (i in 0 until root.childCount) {
                prepareReadiumWebViews(root.getChildAt(i))
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun disableWebViewDarkening(webView: WebView) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            webView.settings.isAlgorithmicDarkeningAllowed = false
        } else if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            webView.settings.forceDark = WebSettings.FORCE_DARK_OFF
        }
    }

    private fun injectMediaColorReset(webView: WebView) {
        webView.evaluateJavascript(
            """
            (function() {
                const id = 'enve-media-color-reset';
                let style = document.getElementById(id);
                if (!style) {
                    style = document.createElement('style');
                    style.id = id;
                    (document.head || document.documentElement).appendChild(style);
                }
                style.textContent = 'img, picture, video, canvas, svg, image { filter: none !important; mix-blend-mode: normal !important; background-blend-mode: normal !important; }';
            })();
            """.trimIndent(),
            null,
        )
    }

    companion object {
        private const val EXTRA_BOOK_ID       = "bookId"
        private const val EXTRA_BOOK_SOURCE   = "bookSource"
        private const val EXTRA_CONNECTION_ID = "connectionId"
        private const val EXTRA_TITLE         = "title"
        private const val EXTRA_AUTHOR        = "author"
        private const val EXTRA_BOOK_FORMAT   = "bookFormat"
        private const val EXTRA_EPUB_LOCATOR  = "epubLocator"
        private const val EXTRA_EPUB_PROGRESS = "epubProgress"
        private const val EXTRA_LAST_READ_TIME = "lastReadTime"
        private const val EXTRA_READER_ENGINE = "readerEngine"
        private const val FOLIATE_STARTUP_ATTEMPTS = 2
        private const val FOLIATE_RETRY_DELAY_MS = 500L
        private const val OPEN_WATCHDOG_MS = 300_000L
        private const val REMOTE_PROGRESS_TIMEOUT_MS = 15_000L
        private const val AUDIO_SEEDED_PROGRESS_TOLERANCE = 0.005f
        private const val ZIP_END_RECORD_BYTES = 22L
        private const val MAX_ZIP_END_RECORD_SEARCH_BYTES = 65_557L

        fun createIntent(
            context: Context,
            bookId: String,
            bookSource: BookSource,
            connectionId: String? = null,
            title: String,
            author: String,
            bookFormat: String?,
            epubLocator: String?,
            epubProgress: Float,
            lastReadTime: Long = 0L,
            readerEngine: ReaderEngineKind? = null,
        ): Intent = Intent(context, EbookReaderActivity::class.java).apply {
            putExtra(EXTRA_BOOK_ID, bookId)
            putExtra(EXTRA_BOOK_SOURCE, bookSource.name)
            if (connectionId != null) putExtra(EXTRA_CONNECTION_ID, connectionId)
            putExtra(EXTRA_TITLE, title)
            putExtra(EXTRA_AUTHOR, author)
            if (bookFormat != null) putExtra(EXTRA_BOOK_FORMAT, bookFormat)
            if (epubLocator != null) putExtra(EXTRA_EPUB_LOCATOR, epubLocator)
            putExtra(EXTRA_EPUB_PROGRESS, epubProgress)
            if (lastReadTime > 0L) putExtra(EXTRA_LAST_READ_TIME, lastReadTime)
            val selectedEngine = ReaderEnginePolicy.select(
                ReaderEngineRequest(
                    source = bookSource,
                    format = bookFormat,
                    readAlong = bookFormat.equals("READALOUD", ignoreCase = true),
                    override = readerEngine,
                ),
            )
            putExtra(EXTRA_READER_ENGINE, selectedEngine.name)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        supportFragmentManager.fragmentFactory = EpubNavigatorFragment.createDummyFactory()
        super.onCreate(null)

        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_ebook_reader)

        loadingRoot    = findViewById(R.id.loading_container)
        loadingText    = findViewById(R.id.loading_text)
        loadingBar     = findViewById(R.id.loading_progress_bar)
        loadingPct     = findViewById(R.id.loading_percent)
        epubContainer  = findViewById(R.id.epub_container)
        composeOverlay = findViewById(R.id.compose_overlay)
        ViewCompat.setOnApplyWindowInsetsListener(epubContainer) { _, insets ->
            epubContainerSafeInsets = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
            )
            applyEpubContainerPadding()
            insets
        }
        ViewCompat.requestApplyInsets(epubContainer)

        bookId     = intent.getStringExtra(EXTRA_BOOK_ID)    ?: run { finish(); return }
        bookSource = intent.getStringExtra(EXTRA_BOOK_SOURCE)?.let { runCatching { BookSource.valueOf(it) }.getOrNull() } ?: BookSource.GRIMMORY
        val connectionId = intent.getStringExtra(EXTRA_CONNECTION_ID)
        bookConnectionId = connectionId
        if (savedInstanceState == null) {
            lifecycleScope.launch { lastOpenedBookStore.record(bookId, bookSource, connectionId) }
        }
        bookTitle  = intent.getStringExtra(EXTRA_TITLE)       ?: ""
        bookAuthor = intent.getStringExtra(EXTRA_AUTHOR)      ?: ""
        val bookFormat = intent.getStringExtra(EXTRA_BOOK_FORMAT)
        val locatorJson = intent.getStringExtra(EXTRA_EPUB_LOCATOR)
        val epubProgress = intent.getFloatExtra(EXTRA_EPUB_PROGRESS, 0f)
        val lastReadTime = intent.getLongExtra(EXTRA_LAST_READ_TIME, 0L)
        this.bookLastReadTime = lastReadTime
        requestedReaderEngine = intent.getStringExtra(EXTRA_READER_ENGINE)
            ?.let { runCatching { ReaderEngineKind.valueOf(it) }.getOrNull() }
            ?: ReaderEnginePolicy.select(
                ReaderEngineRequest(
                    source = bookSource,
                    format = bookFormat,
                    readAlong = bookFormat.equals("READALOUD", ignoreCase = true),
                ),
            )

        vm.init(bookId, bookSource, connectionId, bookTitle, bookAuthor)

        initTts()

        composeOverlay.setContent {
            val themeState by themeViewModel.themeState.collectAsStateWithLifecycle()
            val readerState by vm.state.collectAsStateWithLifecycle()
            val readerTheme = readerState.prefs.theme
            val readerBackground = if (requestedReaderEngine == ReaderEngineKind.FOLIATE) {
                when (readerTheme) {
                    ReaderTheme.LIGHT -> android.graphics.Color.WHITE
                    ReaderTheme.SEPIA -> 0xFFF4ECD8.toInt()
                    ReaderTheme.DARK -> 0xFF121212.toInt()
                    ReaderTheme.OLED -> android.graphics.Color.BLACK
                }
            } else {
                readerState.prefs.toEpubPreferences().theme!!.backgroundColor
            }
            DisposableEffect(readerTheme, readerBackground) {
                window.setBackgroundDrawable(ColorDrawable(readerBackground))
                epubContainer.setBackgroundColor(readerBackground)
                val systemBarStyle = if (readerTheme == ReaderTheme.LIGHT || readerTheme == ReaderTheme.SEPIA) {
                    SystemBarStyle.light(readerBackground, readerBackground)
                } else {
                    SystemBarStyle.dark(readerBackground)
                }
                enableEdgeToEdge(statusBarStyle = systemBarStyle, navigationBarStyle = systemBarStyle)
                onDispose { }
            }
            DisposableEffect(readerState.showChrome) {
                val controller = WindowCompat.getInsetsController(window, window.decorView)
                val systemBars = WindowInsetsCompat.Type.statusBars() or
                    WindowInsetsCompat.Type.navigationBars()
                if (readerState.showChrome) {
                    controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_DEFAULT
                    controller.show(systemBars)
                } else {
                    controller.systemBarsBehavior =
                        WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    controller.hide(systemBars)
                }
                onDispose {
                    controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_DEFAULT
                    controller.show(systemBars)
                }
            }
            val uiTextScale by hearthPreferences.uiTextScale.collectAsStateWithLifecycle(initialValue = 1f)
            val readNextEnabled by hearthPreferences.readNextEnabled.collectAsStateWithLifecycle(initialValue = true)
            val readNextPosition by hearthPreferences.readNextPosition.collectAsStateWithLifecycle(
                initialValue = ReadNextPosition.BOTTOM,
            )
            val restReminder = com.enve.app.ui.screens.reader.rememberReaderRestReminderSpec(hearthPreferences)
            val onReadNext: (Book) -> Unit = { next ->
                startActivity(readerIntentForBook(next))
                finish()
            }
            val onAskLibrarian: () -> Unit = {
                startActivity(
                    EbookLibrarianActivity.createIntent(
                        context = this@EbookReaderActivity,
                        bookId = bookId,
                        bookSource = bookSource,
                        connectionId = connectionId,
                        title = bookTitle,
                        author = bookAuthor,
                        bookFormat = bookFormat,
                        currentProgress = vm.currentReadingProgress(),
                    ),
                )
            }
            com.enve.hearth.design.HearthUiTextScale(uiTextScale) {
                com.enve.app.ui.screens.reader.HearthReaderChrome(
                    vm = vm,
                    bookTitle = bookTitle,
                    bookAuthor = bookAuthor,
                    accentColor = com.enve.hearth.design.EmberAccent,
                    onBack = { finish() },
                    onAskLibrarian = onAskLibrarian,
                    onVerticalMarginsChanged = { margin -> applyVerticalReadingPadding(margin) },
                    einkActive = themeState.einkProfile.active,
                    readNextEnabled = readNextEnabled,
                    readNextPosition = readNextPosition,
                    onReadNext = onReadNext,
                    restReminder = restReminder,
                )
                readerState.pendingProgressConflict?.let { prompt ->
                    EnveTheme(
                        appTheme = themeState.effectiveAppTheme,
                        themeColor = themeState.themeColor,
                        dynamicBackgroundEnabled = themeState.dynamicBackgroundEnabled,
                        einkProfile = themeState.einkProfile,
                    ) {
                        ProgressConflictDialog(
                            prompt = prompt,
                            onChooseLocal = {
                                vm.resolveProgressConflict(com.enve.app.viewmodel.ProgressConflictChoice.LOCAL)
                            },
                            onChooseRemote = {
                                vm.resolveProgressConflict(com.enve.app.viewmodel.ProgressConflictChoice.REMOTE)
                            },
                            onDecideLater = {
                                vm.resolveProgressConflict(com.enve.app.viewmodel.ProgressConflictChoice.LATER)
                            },
                        )
                    }
                }
            }
        }

        lifecycleScope.launch {
            val load = launch { loadBook(bookId, locatorJson, epubProgress, bookFormat) }
            val completed = awaitWithinActiveBudget(
                budgetMs = OPEN_WATCHDOG_MS,
                pausedMs = ::userDecisionElapsedMs,
                await = { budget -> withTimeoutOrNull(budget) { load.join() } != null },
            )
            if (!completed) {
                load.cancel()
                android.util.Log.w("EbookReader", "loadBook exceeded 5m watchdog")
                showError(
                    "Opening this book is taking longer than expected.\n\n" +
                        "Tap back and try again, or check that the book file is " +
                        "intact.",
                )
            }
        }
    }

    private suspend fun loadBook(bookId: String, locatorJson: String?, epubProgress: Float, bookFormat: String?) {
        val sourceFormat = if (bookFormat.isNullOrBlank()) {
            EbookSourceFormat.EPUB
        } else {
            EbookSourceFormat.fromServerType(bookFormat)
        }

        val openStartMs = android.os.SystemClock.elapsedRealtime()
        fun logPhase(phase: String, startMs: Long) {
            android.util.Log.i(
                "EbookReader",
                "phase=$phase ms=${android.os.SystemClock.elapsedRealtime() - startMs} totalMs=${android.os.SystemClock.elapsedRealtime() - openStartMs}",
            )
        }

        val hasOfflineSource = comicOfflineStorage.getDownloadedFile(bookId)
            ?.let { it.exists() && it.length() > 0L }
            ?: false
        val networkAvailable = hasNetworkConnection()
        val useReaderNetwork = shouldUseReaderNetwork(
            hasOfflineSource = hasOfflineSource,
            networkAvailable = networkAvailable,
        )
        val ebookResource = if (sourceFormat == EbookSourceFormat.EPUB && useReaderNetwork) {
            runCatching { vm.getEbookResource() }.getOrNull()
        } else {
            null
        }
        val downloadStartMs = android.os.SystemClock.elapsedRealtime()
        val sourceFile = try { downloadEbookSource(bookId, sourceFormat, ebookResource) }
        catch (e: Exception) { showError("Download failed: ${e.message}"); return }
        logPhase("downloadOrResolveSource", downloadStartMs)

        val normalizeStartMs = android.os.SystemClock.elapsedRealtime()
        val epubFile = try {
            setStatus(if (sourceFormat == EbookSourceFormat.EPUB || sourceFormat == EbookSourceFormat.READALOUD) "Opening book…" else "Converting ${sourceFormat.displayName}…")
            OnDeviceEbookNormalizer(
                kindleConverter = NativeKindleEpubConverter(applicationContext),
            ).normalizeToEpub(
                source = sourceFile,
                format = sourceFormat,
                outputDir = File(cacheDir, "normalized-ebooks"),
                outputName = bookId.replace(Regex("[^a-zA-Z0-9_-]"), "_"),
            )
        } catch (e: EbookNormalizationException) {
            showError(e.message ?: "Could not prepare this ebook.")
            return
        } catch (e: Exception) {
            showError("Could not prepare this ebook: ${e.message}")
            return
        }
        logPhase("normalizeToEpub", normalizeStartMs)

        if (!looksLikeZip(epubFile)) {
            showError("This file is not a valid EPUB package. It may be a PDF/CBZ or the server returned an invalid download.")
            return
        }

        setStatus("Opening book\u2026")

        if (!vm.state.value.isReady) {
            vm.state.first { it.isReady }
        }

        val customFonts = runCatching { customFontRepository.listFonts() }.getOrDefault(emptyList())
        val publicationSha256 = withContext(Dispatchers.IO) { epubFile.sha256() }
        val mayUseFoliate = requestedReaderEngine == ReaderEngineKind.FOLIATE &&
            sourceFormat == EbookSourceFormat.EPUB &&
            ebookResource?.format.equals("EPUB", ignoreCase = true) &&
            FoliateReaderEngine.isSupported() &&
            withContext(Dispatchers.IO) { isReflowableEpub(epubFile) }
        if (mayUseFoliate) {
            val syncBook = currentSyncBook(locatorJson, epubProgress)
            syncCoordinator.registerBook(syncBook)
            lifecycleScope.launch {
                runCatching { syncCoordinator.pullAnnotations(syncBook) }
                syncCoordinator.flushAnnotations(syncBook.id)
            }
            val openProgress = resolveOpenProgress(
                locatorJson = locatorJson,
                epubProgress = epubProgress,
                networkAvailable = networkAvailable,
                pullAnnotations = false,
                cached = vm.cachedReaderProgress(),
                epubFile = epubFile,
                publication = null,
            )
            val plan = vm.prepareEpubEngineOpen(
                engine = ReaderEngineKind.FOLIATE,
                resource = requireNotNull(ebookResource),
                publicationSha256 = publicationSha256,
                launcherLocator = openProgress.resolution.locatorJson,
                launcherProgress = openProgress.resolution.progress,
                launcherUpdatedAt = bookLastReadTime,
                remote = openProgress.remote,
            )
            openFoliate(
                epubFile = epubFile,
                plan = plan,
                customFonts = customFonts,
                locatorJson = locatorJson,
                epubProgress = epubProgress,
                bookFormat = bookFormat,
            )
            return
        }

        requestedReaderEngine = ReaderEngineKind.READIUM
        val readium  = (application as EnveApplication).readiumManager
        val customFontResources = ReadiumCustomFontResources(assets, customFonts)
        val readiumOpenStartMs = android.os.SystemClock.elapsedRealtime()
        val asset    = readium.assetRetriever.retrieve(epubFile).getOrElse {
            discardUnreadableEbookCache(sourceFile, epubFile)
            showError("Cannot read EPUB: ${it.describe()}"); return }
        val publication = readium.publicationOpener.open(
            asset = asset,
            allowUserInteraction = false,
            onCreatePublication = {
                if (!customFontResources.isEmpty) {
                    container = CompositeContainer(customFontResources, container)
                    manifest = manifest.copy(resources = manifest.resources + customFontResources.links)
                }
            },
        ).getOrElse {
            discardUnreadableEbookCache(sourceFile, epubFile)
            showError("Cannot parse EPUB: ${it.describe()}"); return
        }
        logPhase("readiumOpen", readiumOpenStartMs)

        val syncStartMs = android.os.SystemClock.elapsedRealtime()
        val cachedReaderProgress = vm.cachedReaderProgress()
        val openProgress = resolveOpenProgress(
            locatorJson = locatorJson,
            epubProgress = epubProgress,
            networkAvailable = networkAvailable,
            pullAnnotations = true,
            cached = cachedReaderProgress,
            epubFile = epubFile,
            publication = publication,
        )
        val progressResolution = openProgress.resolution
        val readiumBridgePlan = ebookResource?.let { resource ->
            vm.prepareEpubEngineOpen(
                engine = ReaderEngineKind.READIUM,
                resource = resource,
                publicationSha256 = publicationSha256,
                launcherLocator = progressResolution.locatorJson,
                launcherProgress = progressResolution.progress,
                launcherUpdatedAt = bookLastReadTime,
                remote = openProgress.remote,
            )
        }
        val bridgedCheckpoint = readiumBridgePlan?.initialCheckpoint
        val resolvedLocatorJson = bridgedCheckpoint
            ?.let(EpubBridgeCheckpointCodec::toReadiumLocatorJson)
            ?: progressResolution.locatorJson
        val resolvedProgress = bridgedCheckpoint
            ?.totalProgression
            ?.toFloat()
            ?: progressResolution.progress
        logPhase("pullRemoteProgress", syncStartMs)

        val positionsStartMs = android.os.SystemClock.elapsedRealtime()
        val positions = withContext(Dispatchers.Default) {
            try {
                publication.positionsByReadingOrder().flatten()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                emptyList()
            }
        }
        logPhase("positionsByReadingOrder", positionsStartMs)

        val progressLocator: Locator? = buildInitialLocator(
            publication = publication,
            positions = positions,
            locatorJson = resolvedLocatorJson,
            progress = resolvedProgress,
            bookSource = bookSource,
        )
        val audioResumeSec = selectAudioResumeSeconds(
            locatorAudioSeconds = audioPositionSecondsFromLocatorJson(resolvedLocatorJson),
            cachedAudioSeconds = cachedReaderProgress?.currentTimeSec,
            mayUseCachedAudioPosition = progressResolution.mayUseCachedAudioPosition,
        )
        val initialLocator: Locator? = if (
            sourceFormat == EbookSourceFormat.READALOUD &&
            audioResumeSec != null &&
            shouldPreferAudioResumeLocator(
                locatorJson = resolvedLocatorJson,
                resolvedProgress = resolvedProgress,
            )
        ) {
            val readAloudTracks = vm.loadStorytellerReadAloudAudioTracks()
            buildReadAloudInitialLocatorFromAudio(
                publication = publication,
                epubFile = epubFile,
                position = AudioLocatorPosition(timeMs = audioResumeSec * 1000L, progression = 0.0),
                audioTracks = readAloudTracks,
            ) ?: progressLocator
        } else {
            progressLocator
        }

        val einkBoldNow = einkManager.einkActive && einkManager.boldText.value
        val einkActiveNow = einkManager.einkActive
        val initialPrefs = vm.state.value.prefs.toEpubPreferences(einkBoldText = einkBoldNow, einkActive = einkActiveNow)

        val selectionCallback = ReaderSelectionCallback(
            onShowPopup = { vm.showSelectionPopup() },
            onClearSelection = { vm.clearSelection() },
        )
        this.selectionCallback = selectionCallback

        val factory = EpubNavigatorFactory(publication)
            .createFragmentFactory(
                initialLocator = initialLocator,
                initialPreferences = initialPrefs,
                listener = object : EpubNavigatorFragment.Listener {
                    override fun shouldFollowInternalLink(
                        link: Link,
                        context: HyperlinkNavigator.LinkContext?,
                    ): Boolean {
                        val footnote = context as? HyperlinkNavigator.FootnoteContext ?: return true
                        runOnUiThread { showReadiumFootnote(footnote.noteContent) }
                        return false
                    }

                    override fun onExternalLinkActivated(url: AbsoluteUrl) {
                        runCatching {
                            startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url.toString())))
                        }
                    }
                },
                configuration  = EpubNavigatorFragment.Configuration {
                    selectionActionModeCallback = selectionCallback
                    decorationTemplates[com.enve.app.readium.StrikethroughStyle::class] =
                        com.enve.app.readium.strikethroughTemplate()
                    decorationTemplates[com.enve.app.readium.SquigglyStyle::class] =
                        com.enve.app.readium.squigglyTemplate()
                    BUNDLED_READER_FONTS
                        .filter { it.declareInReadium }
                        .forEach { font ->
                            addFontFamilyDeclaration(
                                fontFamily = org.readium.r2.navigator.preferences.FontFamily(font.family),
                            ) {
                                font.faces.forEach { face ->
                                    customFontResources.sourceUrl(face)?.let { source ->
                                        addFontFace {
                                            addSource(source)
                                            setFontWeight(
                                                if (face.weight >= 700) {
                                                    org.readium.r2.navigator.epub.css.FontWeight.BOLD
                                                } else {
                                                    org.readium.r2.navigator.epub.css.FontWeight.NORMAL
                                                },
                                            )
                                            setFontStyle(
                                                if (face.italic) {
                                                    org.readium.r2.navigator.epub.css.FontStyle.ITALIC
                                                } else {
                                                    org.readium.r2.navigator.epub.css.FontStyle.NORMAL
                                                },
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    customFonts.forEach { font ->
                        val regular = customFontResources.sourceUrl(font.id, CustomFontRepository.Variant.REGULAR)
                        val bold = customFontResources.sourceUrl(font.id, CustomFontRepository.Variant.BOLD)
                        val italic = customFontResources.sourceUrl(font.id, CustomFontRepository.Variant.ITALIC)
                        val boldItalic = customFontResources.sourceUrl(font.id, CustomFontRepository.Variant.BOLD_ITALIC)
                        if (regular == null && bold == null && italic == null && boldItalic == null) return@forEach
                        addFontFamilyDeclaration(
                            fontFamily = org.readium.r2.navigator.preferences.FontFamily(font.displayName),
                        ) {
                            regular?.let { source ->
                                addFontFace {
                                    addSource(source)
                                    setFontWeight(org.readium.r2.navigator.epub.css.FontWeight.NORMAL)
                                    setFontStyle(org.readium.r2.navigator.epub.css.FontStyle.NORMAL)
                                }
                            }
                            bold?.let { source ->
                                addFontFace {
                                    addSource(source)
                                    setFontWeight(org.readium.r2.navigator.epub.css.FontWeight.BOLD)
                                    setFontStyle(org.readium.r2.navigator.epub.css.FontStyle.NORMAL)
                                }
                            }
                            italic?.let { source ->
                                addFontFace {
                                    addSource(source)
                                    setFontWeight(org.readium.r2.navigator.epub.css.FontWeight.NORMAL)
                                    setFontStyle(org.readium.r2.navigator.epub.css.FontStyle.ITALIC)
                                }
                            }
                            boldItalic?.let { source ->
                                addFontFace {
                                    addSource(source)
                                    setFontWeight(org.readium.r2.navigator.epub.css.FontWeight.BOLD)
                                    setFontStyle(org.readium.r2.navigator.epub.css.FontStyle.ITALIC)
                                }
                            }
                        }
                    }
                },
            )
        supportFragmentManager.fragmentFactory = factory

        if (isFinishing || isDestroyed || supportFragmentManager.isStateSaved) return

        val navCommitStartMs = android.os.SystemClock.elapsedRealtime()
        supportFragmentManager.commitNow {
            replace(R.id.epub_container, EpubNavigatorFragment::class.java, Bundle(), "epub_nav")
        }
        logPhase("navigatorCommitNow", navCommitStartMs)

        val nav = supportFragmentManager.findFragmentByTag("epub_nav") as? EpubNavigatorFragment
            ?: run { showError("Navigator failed to start"); return }

        readiumNavigator = nav
        readiumFootnoteReturnLocator = nav.currentLocator.value
        vm.attachNavigator(nav, publication, epubFile = epubFile)
        epubContainer.post { prepareReadiumWebViews(epubContainer) }
        lifecycleScope.launch {
            nav.currentLocator.debounce(250).collect { locator ->
                if (readiumFootnoteDialog == null) {
                    readiumFootnoteReturnLocator = locator
                }
            }
        }

        runCatching {
            (nav as? org.readium.r2.navigator.DecorableNavigator)?.addDecorationListener(
                "annotations",
                object : org.readium.r2.navigator.DecorableNavigator.Listener {
                    override fun onDecorationActivated(
                        event: org.readium.r2.navigator.DecorableNavigator.OnActivatedEvent,
                    ): Boolean {
                        val id = event.decoration.id
                        if (vm.annotationForDecoration(id) != null) {
                            vm.showDecorationPopover(id)
                            return true
                        }
                        return false
                    }
                },
            )
        }

        lifecycleScope.launch {
            nav.currentLocator
                .map { it.href.toString() }
                .distinctUntilChanged()
                .drop(1)
                .debounce(120)
                .collect {
                    prepareReadiumWebViews(epubContainer)
                    refreshEinkOnChapterBoundary()

                }
        }

        logPhase("readyToShowNavigator", openStartMs)
        showReaderSurface()

    }

    private fun openFoliate(
        epubFile: File,
        plan: FoliateOpenPlan,
        customFonts: List<com.enve.app.data.reader.CustomFont>,
        locatorJson: String?,
        epubProgress: Float,
        bookFormat: String?,
        startupAttempt: Int = 1,
    ) {
        foliateReady = false
        foliateFallbackStarted = false
        epubContainer.visibility = View.VISIBLE
        epubContainer.alpha = 0f
        val startCompatibilityFallback: (String) -> Unit = { status ->
            if (!foliateFallbackStarted) {
                foliateFallbackStarted = true
                lifecycleScope.launch {
                    foliateEngine?.close()
                    foliateEngine = null
                    requestedReaderEngine = ReaderEngineKind.READIUM
                    loadingRoot.visibility = View.VISIBLE
                    epubContainer.visibility = View.GONE
                    setStatus(status)
                    loadBook(bookId, locatorJson, epubProgress, bookFormat)
                }
            }
        }
        val engine = runCatching {
            FoliateReaderEngine(
                context = this,
                container = epubContainer,
                epubFile = epubFile,
                customFonts = customFonts,
                initialCheckpoint = plan.initialCheckpoint,
                identity = plan.identity,
                initialPreferences = vm.state.value.prefs,
                onReady = ready@ { toc, checkpoint, restoreMethod ->
                    if (!vm.onFoliateReady(toc, checkpoint, restoreMethod)) {
                        startCompatibilityFallback("Opening with the compatible reader…")
                        return@ready
                    }
                    foliateReady = true
                    showReaderSurface()
                },
                onLocation = vm::onFoliateLocation,
                onSelectionChanged = vm::onFoliateSelectionChanged,
                onAnnotationActivated = vm::showDecorationPopover,
                onExternalLink = { uri ->
                    runCatching {
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                    }
                },
                onError = { message ->
                    val requiresCompatibilityFallback = message.startsWith("compatibility:")
                    if (!foliateReady &&
                        startupAttempt < FOLIATE_STARTUP_ATTEMPTS &&
                        !foliateFallbackStarted
                    ) {
                        foliateFallbackStarted = true
                        lifecycleScope.launch {
                            foliateEngine?.close()
                            foliateEngine = null
                            loadingRoot.visibility = View.VISIBLE
                            epubContainer.visibility = View.GONE
                            setStatus("Restarting the book renderer…")
                            delay(FOLIATE_RETRY_DELAY_MS)
                            if (!isFinishing && !isDestroyed) {
                                openFoliate(
                                    epubFile = epubFile,
                                    plan = plan,
                                    customFonts = customFonts,
                                    locatorJson = locatorJson,
                                    epubProgress = epubProgress,
                                    bookFormat = bookFormat,
                                    startupAttempt = startupAttempt + 1,
                                )
                            }
                        }
                    } else if (
                        (!foliateReady || requiresCompatibilityFallback) &&
                        !foliateFallbackStarted
                    ) {
                        startCompatibilityFallback("Opening with the compatible reader…")
                    } else {
                        showError(message)
                    }
                },
            )
        }.getOrElse {
            requestedReaderEngine = ReaderEngineKind.READIUM
            lifecycleScope.launch {
                setStatus("Opening with the compatible reader…")
                loadBook(bookId, locatorJson, epubProgress, bookFormat)
            }
            return
        }
        foliateEngine = engine
        vm.attachEngineNavigator(engine, plan)
    }

    private fun showReaderSurface() {
        if (isFinishing || isDestroyed) return
        loadingRoot.visibility = View.GONE
        epubContainer.visibility = View.VISIBLE
        epubContainer.alpha = 1f
        composeOverlay.visibility = View.VISIBLE
        composeOverlay.elevation = 16f
        composeOverlay.translationZ = 16f
        (composeOverlay.parent as? FrameLayout)?.let { parent ->
            val layoutParams = composeOverlay.layoutParams
            parent.removeView(composeOverlay)
            parent.addView(composeOverlay, layoutParams)
        }
        composeOverlay.bringToFront()
    }

    private suspend fun buildReadAloudInitialLocatorFromAudio(
        publication: org.readium.r2.shared.publication.Publication,
        epubFile: File,
        position: AudioLocatorPosition,
        audioTracks: List<AudioTrack>,
    ): Locator? {
        val engine = MediaOverlayEngine(applicationContext, publication, lifecycleScope, sourceFile = epubFile)
        return try {
            engine.setAudioTimeline(audioTracks)
            val clip = engine.clipForAudioPosition(position) ?: return null
            readAloudLocatorFromClip(
                publication = publication,
                clip = clip,
                totalProgression = MediaOverlayTextProgression.readingProgression(
                    textProgression = clip.textProgression,
                    narrationCompleted = position.progression >= 1.0,
                ),
            )
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            android.util.Log.w("EbookReader", "Could not map read-aloud audio time to EPUB locator", e)
            null
        } finally {
            engine.release(stopPlayback = false)
        }
    }

    private fun showReadiumFootnote(content: String) {
        readiumFootnoteDialog?.dismiss()
        val returnLocator = readiumFootnoteReturnLocator
        val message = HtmlCompat.fromHtml(content, HtmlCompat.FROM_HTML_MODE_COMPACT)
        val dialog = android.app.AlertDialog.Builder(this)
            .setTitle(R.string.reader_footnote_title)
            .setMessage(message)
            .setPositiveButton(R.string.reader_footnote_close, null)
            .create()
        dialog.setOnDismissListener {
            if (readiumFootnoteDialog === dialog) {
                readiumFootnoteDialog = null
            }
            if (returnLocator != null) {
                epubContainer.post {
                    readiumNavigator?.go(returnLocator, animated = false)
                }
            }
        }
        readiumFootnoteDialog = dialog
        dialog.show()
        if (returnLocator != null) {
            epubContainer.postDelayed({
                if (readiumFootnoteDialog === dialog) {
                    readiumNavigator?.go(returnLocator, animated = false)
                }
            }, 100)
        }
    }

    private fun readAloudLocatorFromClip(
        publication: org.readium.r2.shared.publication.Publication,
        clip: SmilClip,
        totalProgression: Double?,
    ): Locator? {
        val href = parsePublicationHref(clip.textHref) ?: return null
        val manifestLink = publication.linkWithHref(href)
        val baseLocator = manifestLink
            ?.let(publication::locatorFromLink)
            ?: Locator(
                href = href,
                mediaType = manifestLink?.mediaType ?: MediaType.XHTML,
            )

        return baseLocator.copyWithLocations(
            fragments = clip.textFragmentId?.let(::listOf).orEmpty(),
            progression = clip.resourceProgression ?: baseLocator.locations.progression,
            totalProgression = totalProgression ?: baseLocator.locations.totalProgression,
        )
    }

    private fun parsePublicationHref(href: String?): Url? {
        if (href.isNullOrBlank()) return null
        return Url(href) ?: Url.fromDecodedPath(href)
    }

    private fun audioPositionSecondsFromLocatorJson(locatorJson: String?): Long? {
        if (locatorJson.isNullOrBlank() || !locatorJson.trim().startsWith("{")) return null
        return runCatching {
            val locations = JSONObject(locatorJson).optJSONObject("locations") ?: return@runCatching null
            val fragments = locations.optJSONArray("fragments") ?: return@runCatching null
            for (index in 0 until fragments.length()) {
                val fragment = fragments.optString(index)
                if (fragment.startsWith("t=")) {
                    return@runCatching fragment.removePrefix("t=")
                        .toDoubleOrNull()
                        ?.roundToLong()
                        ?.coerceAtLeast(0L)
                }
            }
            null
        }.getOrNull()
    }

    private fun shouldPreferAudioResumeLocator(
        locatorJson: String?,
        resolvedProgress: Float,
    ): Boolean {
        if (!isDirectRestorableLocatorForOpen(locatorJson)) return true
        val locatorProgress = locatorTotalProgression(locatorJson) ?: return false
        return kotlin.math.abs(locatorProgress - resolvedProgress.coerceIn(0f, 1f)) > 0.01f
    }

    private fun locatorTotalProgression(locatorJson: String?): Float? {
        if (locatorJson.isNullOrBlank() || !locatorJson.trim().startsWith("{")) return null
        return runCatching {
            JSONObject(locatorJson)
                .optJSONObject("locations")
                ?.optDouble("totalProgression")
                ?.takeIf { !it.isNaN() }
                ?.toFloat()
                ?.coerceIn(0f, 1f)
        }.getOrNull()
    }

    private fun isDirectRestorableLocatorForOpen(locatorJson: String?): Boolean {
        if (locatorJson.isNullOrBlank() || !locatorJson.trim().startsWith("{")) return false
        return runCatching {
            val parsed = Locator.fromJSON(JSONObject(locatorJson))
            parsed != null &&
                parsed.href.toString().isNotBlank() &&
                (bookSource != BookSource.GRIMMORY || isDirectRestorableReadiumLocator(locatorJson))
        }.getOrDefault(false)
    }

    private fun buildInitialLocator(
        publication: org.readium.r2.shared.publication.Publication,
        positions: List<Locator>,
        locatorJson: String?,
        progress: Float,
        bookSource: BookSource,
    ): Locator? {
        val normalized = progress.coerceIn(0f, 1f)

        if (locatorJson != null && locatorJson.trim().startsWith("{")) {
            try {
                val parsed = Locator.fromJSON(JSONObject(locatorJson))
                val canUseParsedLocator = bookSource != BookSource.GRIMMORY ||
                    isDirectRestorableReadiumLocator(locatorJson)
                if (parsed != null && parsed.href.toString().isNotBlank() && canUseParsedLocator) {
                    return parsed
                }
            } catch (_: Exception) {}
        }

        val baseLocator = if (positions.isNotEmpty()) {
            val idx = (normalized * positions.size).toInt().coerceIn(0, positions.size - 1)
            positions[idx]
        } else {
            val firstLink = publication.readingOrder.firstOrNull() ?: return null
            Locator(
                href = firstLink.url().removeFragment(),
                mediaType = firstLink.mediaType ?: org.readium.r2.shared.util.mediatype.MediaType.XHTML,
                locations = Locator.Locations(totalProgression = normalized.toDouble())
            )
        }

        return if (normalized > 0.0001f) {
            baseLocator.copy(
                locations = baseLocator.locations.copy(
                    totalProgression = normalized.toDouble()
                )
            )
        } else {
            baseLocator
        }
    }

    private fun isDirectRestorableReadiumLocator(locatorJson: String): Boolean {
        return try {
            val json = JSONObject(locatorJson)
            val highlight = json.optJSONObject("text")
                ?.optString("highlight")
                ?.trim()
                .orEmpty()
            if (highlight.length >= 8) return true

            val locations = json.optJSONObject("locations") ?: return false
            locations.optString("cssSelector").isNotBlank() ||
                locations.optJSONObject("domRange")?.optJSONObject("start")
                    ?.optString("cssSelector")
                    ?.isNotBlank() == true
        } catch (_: Exception) {
            false
        }
    }

    private suspend fun resolveOpenProgress(
        locatorJson: String?,
        epubProgress: Float,
        networkAvailable: Boolean,
        pullAnnotations: Boolean,
        cached: CachedReaderProgress?,
        epubFile: File,
        publication: org.readium.r2.shared.publication.Publication?,
    ): OpenProgressPlan {
        openProgressPlan?.let { return it }

        val fallbackLocator = cached?.locator ?: locatorJson
        val fallbackProgress = cached?.progress?.takeIf { it > epubProgress } ?: epubProgress
        val localPlan = OpenProgressPlan(
            resolution = OpenProgressResolution(fallbackLocator, fallbackProgress, mayUseCachedAudioPosition = true),
            remote = OpenRemoteProgress(snapshot = null, authority = OpenProgressAuthority.AUTOMATIC),
        )

        val plan = if (!networkAvailable) {
            localPlan
        } else {
            val startedAt = android.os.SystemClock.elapsedRealtime()
            val outcome = withTimeoutOrNull(REMOTE_PROGRESS_TIMEOUT_MS) {
                pullRemoteProgress(fallbackLocator, fallbackProgress, pullAnnotations, epubFile, publication)
            } ?: run {
                android.util.Log.w(
                    "EbookReader",
                    "pullRemoteProgress timed out after ${android.os.SystemClock.elapsedRealtime() - startedAt}ms; opening with local fallback (intentProgress=$epubProgress, cachedProgress=${cached?.progress}, cachedLocator=${cached?.locator != null})",
                )
                RemoteProgressOutcome.Resolved(localPlan)
            }
            when (outcome) {
                is RemoteProgressOutcome.Resolved -> outcome.plan
                is RemoteProgressOutcome.NeedsChoice -> awaitProgressChoice(outcome, epubFile, publication)
            }
        }
        openProgressPlan = plan
        return plan
    }

    private suspend fun pullRemoteProgress(
        cachedLocatorJson: String?,
        cachedProgress: Float,
        pullAnnotations: Boolean,
        epubFile: File,
        publication: org.readium.r2.shared.publication.Publication?,
    ): RemoteProgressOutcome {
        val book = currentSyncBook(cachedLocatorJson, cachedProgress)
        val fetched = try {
            if (pullAnnotations) syncCoordinator.pullOnOpen(book) else syncCoordinator.fetchSnapshot(book)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
        val audioPosition = AudioLocatorPosition.parse(fetched?.locatorJson)
        val snapshot = fetched?.let { remote ->
            audioPosition?.let { readAloudSnapshotFromAudio(remote, it, epubFile, publication) } ?: remote
        }
        val seededLocal = snapshot?.takeIf {
            audioPosition != null && it.locatorJson != null &&
                kotlin.math.abs(cachedProgress - fetched.percentage) < AUDIO_SEEDED_PROGRESS_TOLERANCE
        }
        val localLocatorJson = seededLocal?.locatorJson ?: cachedLocatorJson
        val localProgress = seededLocal?.percentage ?: cachedProgress
        val result = syncCoordinator.resolveFetchedSnapshot(
            book = book,
            snapshot = snapshot,
            localPercentage = localProgress,
            localUpdatedAt = bookLastReadTime.takeIf { it > 0L },
            localLocatorJson = localLocatorJson,
        )

        return when (result) {
            is com.enve.app.data.sync.SyncCoordinator.OpenSyncResult.Apply -> {
                val authority = if (result.useRemote && result.snapshot != null) {
                    OpenProgressAuthority.REMOTE
                } else if (!result.allowRemoteCheckpoint) {
                    OpenProgressAuthority.LOCAL
                } else {
                    OpenProgressAuthority.AUTOMATIC
                }
                RemoteProgressOutcome.Resolved(
                    OpenProgressPlan(
                        resolution = openProgressResolutionFor(
                            authority = authority,
                            localLocatorJson = localLocatorJson,
                            localProgress = localProgress,
                            remoteLocatorJson = result.snapshot?.locatorJson,
                            remoteProgress = result.snapshot?.percentage ?: localProgress,
                        ),
                        remote = OpenRemoteProgress(result.snapshot, authority),
                    ),
                )
            }
            is com.enve.app.data.sync.SyncCoordinator.OpenSyncResult.Conflict ->
                RemoteProgressOutcome.NeedsChoice(result, snapshot, localLocatorJson, localProgress)
        }
    }

    private suspend fun readAloudSnapshotFromAudio(
        snapshot: SyncSnapshot,
        position: AudioLocatorPosition,
        epubFile: File,
        publication: org.readium.r2.shared.publication.Publication?,
    ): SyncSnapshot {
        val locator = publication?.let {
            buildReadAloudInitialLocatorFromAudio(
                publication = it,
                epubFile = epubFile,
                position = position,
                audioTracks = vm.loadStorytellerReadAloudAudioTracks(),
            )
        } ?: return snapshot.copy(locatorJson = null)
        return snapshot.copy(
            percentage = locator.locations.totalProgression?.toFloat() ?: snapshot.percentage,
            locatorJson = locator.toJSON().toString(),
        )
    }

    private suspend fun awaitProgressChoice(
        pending: RemoteProgressOutcome.NeedsChoice,
        epubFile: File,
        publication: org.readium.r2.shared.publication.Publication?,
    ): OpenProgressPlan {
        val conflict = pending.conflict
        val passages = conflictPassages(conflict, epubFile, publication)

        val choice = awaitingUserDecision {
            vm.awaitProgressConflictChoice(
                com.enve.app.viewmodel.ProgressConflictPrompt(
                    localPercentage = conflict.local.percentage,
                    localUpdatedAt = conflict.local.updatedAt,
                    remotePercentage = conflict.remote.percentage,
                    remoteUpdatedAt = conflict.remote.updatedAt,
                    remoteSource = conflict.remoteSource,
                    localPassage = passages?.first,
                    remotePassage = passages?.second,
                ),
            )
        }
        val acceptedRemote = choice == com.enve.app.viewmodel.ProgressConflictChoice.REMOTE
        if (choice == com.enve.app.viewmodel.ProgressConflictChoice.LATER) {
            vm.holdProgressPushes()
        } else {
            syncCoordinator.recordConflictResolution(
                book = currentSyncBook(pending.localLocatorJson, pending.localProgress),
                remoteSource = conflict.remoteSource,
                acceptedRemote = acceptedRemote,
            )
        }

        val authority = if (acceptedRemote) OpenProgressAuthority.REMOTE else OpenProgressAuthority.LOCAL
        return OpenProgressPlan(
            resolution = openProgressResolutionFor(
                authority = authority,
                localLocatorJson = pending.localLocatorJson,
                localProgress = pending.localProgress,
                remoteLocatorJson = conflict.remote.locatorJson,
                remoteProgress = conflict.remote.percentage,
            ),
            remote = OpenRemoteProgress(pending.snapshot, authority),
        )
    }

    private suspend fun conflictPassages(
        conflict: com.enve.app.data.sync.SyncCoordinator.OpenSyncResult.Conflict,
        epubFile: File,
        publication: org.readium.r2.shared.publication.Publication?,
    ): Pair<ProgressConflictPassage?, ProgressConflictPassage?>? {
        suspend fun passages(
            target: org.readium.r2.shared.publication.Publication,
        ): Pair<ProgressConflictPassage?, ProgressConflictPassage?>? = try {
            progressConflictPassages.passages(
                publication = target,
                localLocatorJson = conflict.local.locatorJson,
                localPercentage = conflict.local.percentage,
                remoteLocatorJson = conflict.remote.locatorJson,
                remotePercentage = conflict.remote.percentage,
            )
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }

        if (publication != null) return passages(publication)

        val readium = (application as EnveApplication).readiumManager
        val asset = readium.assetRetriever.retrieve(epubFile).getOrElse { return null }
        val preview = readium.publicationOpener.open(asset, allowUserInteraction = false).getOrElse {
            withContext(Dispatchers.IO) { runCatching { asset.close() } }
            return null
        }
        return try {
            passages(preview)
        } finally {
            withContext(Dispatchers.IO) { runCatching { preview.close() } }
        }
    }

    private fun userDecisionElapsedMs(): Long {
        val pending = userDecisionStartedAtMs
            .takeIf { it > 0L }
            ?.let { android.os.SystemClock.elapsedRealtime() - it }
            ?: 0L
        return userDecisionTotalMs + pending
    }

    private suspend fun <T> awaitingUserDecision(block: suspend () -> T): T {
        userDecisionStartedAtMs = android.os.SystemClock.elapsedRealtime()
        return try {
            block()
        } finally {
            userDecisionTotalMs += android.os.SystemClock.elapsedRealtime() - userDecisionStartedAtMs
            userDecisionStartedAtMs = 0L
        }
    }

    private fun currentSyncBook(
        localLocatorJson: String?,
        localProgress: Float,
    ) = com.enve.core.data.model.Book(
            id = bookId,
            title = bookTitle,
            source = bookSource,
            connectionId = bookConnectionId,
            mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
            epubLocator = localLocatorJson,
            epubProgress = localProgress,

            lastReadTime = bookLastReadTime,
        )

    private suspend fun downloadEbookSource(
        bookId: String,
        format: EbookSourceFormat,
        resource: ProviderEbookResource? = null,
    ): File {

        val offlineFile = comicOfflineStorage.getDownloadedFile(bookId)
        if (offlineFile != null && offlineFile.exists() && offlineFile.length() > 0) {
            setStatus("Loading offline ${format.displayName}\u2026")
            validateDownloadedEbookSource(offlineFile, format)
            return offlineFile
        }

        val dir      = File(cacheDir, "ebooks").also { it.mkdirs() }
        val safeName = bookId.replace(Regex("[^a-zA-Z0-9_-]"), "_")
        val fileDiscriminator = resource?.providerFileId
            ?.replace(Regex("[^a-zA-Z0-9_-]"), "_")
            ?.takeIf { it.isNotBlank() }
            ?.let { ".$it" }
            .orEmpty()
        val cachedName = if (format == EbookSourceFormat.READALOUD) {
            "$safeName.readaloud.${format.extension}"
        } else {
            "$safeName$fileDiscriminator.${format.extension}"
        }
        val cached   = File(dir, cachedName)

        if (cached.exists() && cached.length() > 0) {
            if (isZipBackedEbook(format) && !looksLikeZip(cached)) {
                cached.delete()
            } else {
                setStatus("Loading cached ${format.displayName}\u2026")
                return cached
            }
        }

        setStatus("Downloading\u2026")
        withContext(Dispatchers.Main) {
            loadingBar.visibility = View.VISIBLE
            loadingPct.visibility = View.VISIBLE
        }

        val downloadUrl = resource?.url
            ?: vm.getEbookDownloadUrl(readaloud = format == EbookSourceFormat.READALOUD)

        if (downloadUrl.startsWith("content://") || downloadUrl.startsWith("file://")) {
            return withContext(Dispatchers.IO) {
                val tmp = File(dir, "$safeName.tmp")
                val input = contentResolver.openInputStream(android.net.Uri.parse(downloadUrl))
                    ?: throw Exception("Couldn't open the local file. Was it moved or deleted?")
                input.use { inp -> FileOutputStream(tmp).use { out -> inp.copyTo(out) } }
                if (tmp.length() == 0L) { tmp.delete(); throw Exception("File is empty") }
                validateDownloadedEbookSource(tmp, format)
                if (cached.exists()) cached.delete()
                if (!tmp.renameTo(cached)) {
                    tmp.copyTo(cached, overwrite = true)
                    tmp.delete()
                }
                cached
            }
        }

        return withContext(Dispatchers.IO) {
            val downloadClient = okHttpClient.newBuilder()
                .callTimeout(0, TimeUnit.MILLISECONDS)
                .readTimeout(5, TimeUnit.MINUTES)
                .writeTimeout(1, TimeUnit.MINUTES)
                .build()
            val resp = downloadClient.newCall(Request.Builder().url(downloadUrl).build()).execute()
            if (!resp.isSuccessful) throw Exception("HTTP ${resp.code}")
            val body = resp.body ?: throw Exception("Empty body")
            val len  = body.contentLength()
            val tmp  = File(dir, "$safeName.tmp")
            var total = 0L
            FileOutputStream(tmp).use { out ->
                body.byteStream().use { inp ->
                    val buf = ByteArray(16_384); var n: Int
                    var lastUpdateTime = 0L
                    while (inp.read(buf).also { n = it } != -1) {
                        out.write(buf, 0, n); total += n
                        if (len > 0) {
                            val now = System.currentTimeMillis()
                            if (now - lastUpdateTime > 200L) {
                                lastUpdateTime = now
                                val pct = (total * 100 / len).toInt()
                                withContext(Dispatchers.Main) {
                                    loadingBar.progress = pct
                                    loadingPct.text = getString(R.string.loading_percent, pct)
                                }
                            }
                        }
                    }
                }
            }
            if (len > 0 && total != len) {
                tmp.delete()
                throw Exception("The download stopped early — got ${total / 1024} KB of ${len / 1024} KB.")
            }
            if (tmp.length() == 0L) { tmp.delete(); throw Exception("File is empty") }
            validateDownloadedEbookSource(tmp, format)
            if (cached.exists()) cached.delete()
            if (!tmp.renameTo(cached)) {
                tmp.copyTo(cached, overwrite = true)
                tmp.delete()
            }
            cached
        }
    }

    private fun validateDownloadedEbookSource(file: File, format: EbookSourceFormat) {
        if (!isZipBackedEbook(format)) return
        if (looksLikeZip(file)) return
        file.delete()
        throw Exception("The server did not return a valid ${format.displayName} file.")
    }

    private fun isZipBackedEbook(format: EbookSourceFormat): Boolean =
        format == EbookSourceFormat.EPUB || format == EbookSourceFormat.READALOUD

    @Suppress("DEPRECATION")
    private fun hasNetworkConnection(): Boolean {
        val manager = getSystemService(ConnectivityManager::class.java)
        return manager.allNetworks.any { network ->
            val capabilities = manager.getNetworkCapabilities(network) ?: return@any false
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                (
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                    )
        }
    }

    private fun looksLikeZip(file: File): Boolean {
        if (!file.exists() || file.length() < ZIP_END_RECORD_BYTES) return false
        return runCatching {
            RandomAccessFile(file, "r").use { archive ->
                val header = ByteArray(2)
                archive.readFully(header)
                if (header[0] != 'P'.code.toByte() || header[1] != 'K'.code.toByte()) return@use false
                val tailLength = minOf(archive.length(), MAX_ZIP_END_RECORD_SEARCH_BYTES).toInt()
                val tail = ByteArray(tailLength)
                archive.seek(archive.length() - tailLength)
                archive.readFully(tail)
                (tail.size - 4 downTo 0).any { index ->
                    tail[index] == 'P'.code.toByte() && tail[index + 1] == 'K'.code.toByte() &&
                        tail[index + 2] == 0x05.toByte() && tail[index + 3] == 0x06.toByte()
                }
            }
        }.getOrDefault(false)
    }

    private fun discardUnreadableEbookCache(vararg files: File) {
        val cacheRoot = cacheDir.absolutePath
        files.filter { it.absolutePath.startsWith(cacheRoot) }.forEach { it.delete() }
    }

    private fun File.sha256(): String {
        val digest = MessageDigest.getInstance("SHA-256")
        inputStream().buffered().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    private fun isReflowableEpub(file: File): Boolean = runCatching {
        ZipFile(file).use { zip ->
            val opfEntry = zip.entries().asSequence()
                .filterNot { it.isDirectory }
                .filter { it.name.endsWith(".opf", ignoreCase = true) }
                .minByOrNull { it.name.length }
                ?: return@use false
            val packageDocument = zip.getInputStream(opfEntry)
                .bufferedReader()
                .use { it.readText() }
                .lowercase(Locale.ROOT)
            val fixedLayoutMarkers = listOf(
                "pre-paginated",
                "fixed-layout",
                "rendition:layout-pre-paginated",
                "original-resolution",
            )
            fixedLayoutMarkers.none(packageDocument::contains)
        }
    }.getOrDefault(false)

    private fun setStatus(msg: String) {
        lifecycleScope.launch(Dispatchers.Main) {
            if (!isFinishing && !isDestroyed) loadingText.text = msg
        }
    }

    private fun showError(msg: String) {
        lifecycleScope.launch(Dispatchers.Main) {
            if (isFinishing || isDestroyed) return@launch
            loadingText.text = msg
            loadingBar.visibility = View.GONE
            loadingPct.visibility = View.GONE
        }
    }

    override fun onPause() {
        super.onPause()
        vm.flushPreferences()
        vm.flushProgress()
        vm.pauseReadingSession()
        vm.stopAutoScroll()
        vm.stopTts()
        vm.onReaderBackgrounded()
    }

    override fun onResume() {
        super.onResume()
        vm.resumeReadingSession()
        vm.onReaderForegrounded()
    }

    override fun onDestroy() {
        foliateEngine?.close()
        foliateEngine = null
        readiumFootnoteDialog?.dismiss()
        readiumFootnoteDialog = null
        readiumNavigator = null
        readiumFootnoteReturnLocator = null
        super.onDestroy()
        ttsEngine?.stop()
        ttsEngine?.shutdown()
        ttsEngine = null
        selectionCallback = null
    }

    private fun applyVerticalReadingPadding(margin: Float) {
        val normalized = (margin / 2f).coerceIn(0f, 1f)
        val insetDp = normalized * 48f
        verticalReadingPaddingPx = (insetDp * resources.displayMetrics.density).roundToInt()
        applyEpubContainerPadding()
    }

    private fun applyEpubContainerPadding() {
        val left = epubContainerSafeInsets.left
        val top = epubContainerSafeInsets.top + verticalReadingPaddingPx
        val right = epubContainerSafeInsets.right
        val bottom = epubContainerSafeInsets.bottom + verticalReadingPaddingPx
        if (
            left == epubContainer.paddingLeft && top == epubContainer.paddingTop &&
            right == epubContainer.paddingRight && bottom == epubContainer.paddingBottom
        ) {
            return
        }
        vm.preserveReadiumPositionAcross { epubContainer.setPadding(left, top, right, bottom) }
    }

    private fun initTts() {
        ttsEngine = TextToSpeech(this) { status ->
            if (status != TextToSpeech.SUCCESS) {
                vm.postTransientMessage("Text-to-speech is unavailable on this device.")
                return@TextToSpeech
            }
            val engine = ttsEngine ?: return@TextToSpeech

            val preferred = Locale.getDefault()
            val languageResult = engine.setLanguage(preferred)
            if (languageResult == TextToSpeech.LANG_MISSING_DATA ||
                languageResult == TextToSpeech.LANG_NOT_SUPPORTED) {
                val fallbackResult = engine.setLanguage(Locale.US)
                if (fallbackResult == TextToSpeech.LANG_MISSING_DATA ||
                    fallbackResult == TextToSpeech.LANG_NOT_SUPPORTED) {
                    vm.postTransientMessage(
                        "No text-to-speech voice is installed. Install one from Android settings.",
                    )
                    return@TextToSpeech
                } else {
                    vm.postTransientMessage(
                        "${preferred.displayLanguage} voice not installed. Using English.",
                    )
                }
            }
            vm.setTtsEngine(engine)
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {}
                override fun onDone(utteranceId: String?) {
                    vm.clearTtsHighlight()
                }
                override fun onError(utteranceId: String?, errorCode: Int) {
                    vm.clearTtsHighlight()
                    vm.postTransientMessage("Couldn't speak that selection.")
                }
                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) {
                    vm.clearTtsHighlight()
                }
            })
        }
    }
}

private fun ReadiumError.describe(): String =
    generateSequence(this) { it.cause }
        .take(MAX_READIUM_ERROR_CAUSES)
        .map(ReadiumError::message)
        .filter { it.isNotBlank() }
        .distinct()
        .joinToString(" ")
        .ifBlank { "the file could not be decoded" }

private const val MAX_READIUM_ERROR_CAUSES = 4

private class ReaderSelectionCallback(
    private val onShowPopup: () -> Unit,
    private val onClearSelection: () -> Unit,
) : android.view.ActionMode.Callback {

    @Volatile private var active = false
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val showPopup = Runnable { if (active) onShowPopup() }
    private val clearSelection = Runnable {
        active = false
        onClearSelection()
    }

    fun notifyFingerUp() {
        if (!active) return
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed(showPopup, POPUP_DELAY_MS)
    }

    override fun onCreateActionMode(mode: android.view.ActionMode, menu: android.view.Menu): Boolean {
        handler.removeCallbacksAndMessages(null)
        active = true
        menu.clear()
        handler.postDelayed(showPopup, POPUP_DELAY_MS)
        return true
    }

    override fun onPrepareActionMode(mode: android.view.ActionMode, menu: android.view.Menu): Boolean {
        menu.clear()
        if (active) {
            handler.removeCallbacks(showPopup)
            handler.postDelayed(showPopup, POPUP_DELAY_MS)
        }
        return true
    }

    override fun onDestroyActionMode(mode: android.view.ActionMode) {
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed(clearSelection, ACTION_MODE_REBUILD_GRACE_MS)
    }

    override fun onActionItemClicked(mode: android.view.ActionMode, item: android.view.MenuItem): Boolean {
        mode.finish()
        return true
    }

    private companion object {
        const val POPUP_DELAY_MS = 120L
        const val ACTION_MODE_REBUILD_GRACE_MS = 150L
    }
}
