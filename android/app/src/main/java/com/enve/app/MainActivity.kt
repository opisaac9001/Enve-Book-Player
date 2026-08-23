package com.enve.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.viewModels
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.app.eink.EpdRefreshManager
import com.enve.app.ui.EnveApp
import com.enve.app.ui.Routes
import com.enve.app.ui.readerFormat
import com.enve.app.ui.screens.ReaderFormat
import com.enve.app.ui.screens.buildPageLocator
import com.enve.app.ui.theme.AppTheme
import com.enve.app.ui.theme.EnveTheme
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import com.enve.engine.theme.HearthThemeMode
import com.enve.hearth.design.EmberAccent
import com.enve.hearth.shell.HearthRoot
import com.enve.hearth.settings.HearthSettingsDestination
import com.enve.app.ui.auth.AuthViewModel
import com.enve.app.viewmodel.ThemeViewModel
import androidx.lifecycle.lifecycleScope
import com.enve.app.data.sync.RecentlyPlayedSyncService
import com.enve.core.data.local.PreferencesManager
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.enve.app.ui.components.CastButton

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    private val authViewModel: AuthViewModel by viewModels()
    private val openPlayerFromWidget = kotlinx.coroutines.flow.MutableStateFlow(false)

    @Inject
    lateinit var epdRefreshManager: EpdRefreshManager

    @Inject
    lateinit var recentlyPlayedSyncService: RecentlyPlayedSyncService

    @Inject
    lateinit var preferencesManager: PreferencesManager

    @Inject
    lateinit var hearthPreferences: com.enve.engine.prefs.PreferencesFacade

    private var skipNextResumeRefresh: Boolean = true
    private var lastRefreshAtMs: Long = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        val splashScreen = installSplashScreen()
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        handleAuthCallbackIntent(intent)
        readWidgetIntent(intent)

        if (savedInstanceState == null) {
            lifecycleScope.launch {
                delay(5_000)
                try {
                    if (preferencesManager.autoSyncOnLaunch.first()) {
                        recentlyPlayedSyncService.syncOnLaunch()
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (_: Exception) {
                }
            }
        }

        setContent {

            val uiTextScale by hearthPreferences.uiTextScale.collectAsState(initial = 1f)
            val hearthMode by hearthPreferences.themeMode.collectAsState(initial = HearthThemeMode.SYSTEM)
            val hearthOled by hearthPreferences.oledEnabled.collectAsState(initial = false)
            val hearthAccentHex by hearthPreferences.accentHex.collectAsState(initial = "#F5921A")

            var classicInitialRoute by remember { mutableStateOf<String?>(null) }

            var resumeHearthInSettings by remember { mutableStateOf(false) }
            if (classicInitialRoute == null) {
                val widgetPlayerRequest by openPlayerFromWidget.collectAsState()
                HearthRoot(
                    imageLoader = runCatching { (application as EnveApplication).imageLoader }.getOrNull(),
                    initialShowSettings = resumeHearthInSettings,
                    showPlayerRequest = widgetPlayerRequest,
                    onPlayerRequestConsumed = { openPlayerFromWidget.value = false },
                    playerTopAction = { CastButton(Modifier.size(48.dp)) },
                    onManageSources = {
                        classicInitialRoute = Routes.QUICK_CONNECT
                        resumeHearthInSettings = true
                    },
                    onOpenSettingsDestination = { destination ->
                        classicInitialRoute = destination.toRoute()
                        resumeHearthInSettings = true
                    },
                    onAskLibrarian = { book ->
                        startActivity(
                            com.enve.app.ui.screens.EbookLibrarianActivity.createIntent(
                                context = this,
                                bookId = book.id,
                                bookSource = book.source,
                                connectionId = book.connectionId,
                                title = book.title,
                                author = book.author,
                                bookFormat = book.readerFormat(),
                                currentProgress = (book.epubProgress ?: book.readProgress).toDouble(),
                            )
                        )
                    },
                    onOpenEbook = { book -> openReader(book) },
                    onOpenAnnotation = { book, annotation -> openReader(book, annotation) },
                )
            } else {
                val themeViewModel: ThemeViewModel = hiltViewModel()
                val themeState by themeViewModel.themeState.collectAsState()

                val hearthDark = when (hearthMode) {
                    HearthThemeMode.SYSTEM -> isSystemInDarkTheme()
                    HearthThemeMode.INK -> true
                    HearthThemeMode.PAPER -> false
                }
                val bridgedTheme = when {
                    themeState.einkProfile.monochrome -> themeState.effectiveAppTheme
                    !hearthDark -> AppTheme.PAPER_WHITE
                    hearthOled -> AppTheme.OLED
                    else -> AppTheme.DARK
                }
                val bridgedAccent = remember(hearthAccentHex) {
                    hearthAccentHex.trim().removePrefix("#").takeIf { it.length == 6 }
                        ?.toLongOrNull(16)
                        ?.let { Color(0xFF000000 or it) }
                        ?: EmberAccent
                }

                com.enve.hearth.design.HearthUiTextScale(uiTextScale) {
                    EnveTheme(
                        appTheme = bridgedTheme,
                        themeColor = bridgedAccent,
                        dynamicBackgroundEnabled = false,
                        einkProfile = themeState.einkProfile,
                    ) {
                        EnveApp(
                            epdRefreshManager = epdRefreshManager,
                            initialRoute = classicInitialRoute,
                            onExitInitialRoute = { classicInitialRoute = null },
                        )
                    }
                }
            }
        }
    }

    private fun HearthSettingsDestination.toRoute(): String = when (this) {
        HearthSettingsDestination.Sources -> Routes.QUICK_CONNECT
        HearthSettingsDestination.ServerManagement -> Routes.SERVER_MANAGEMENT
        HearthSettingsDestination.LibraryHub -> Routes.LIBRARY_HUB
        HearthSettingsDestination.Hardcover -> Routes.HARDCOVER_HUB
        HearthSettingsDestination.Metadata -> Routes.METADATA_HUB
        HearthSettingsDestination.StoryAlign -> Routes.STORYALIGN_STUDIO
        HearthSettingsDestination.Downloads -> Routes.DOWNLOADS
        HearthSettingsDestination.Storage -> Routes.STORAGE
        HearthSettingsDestination.SyncCloud -> Routes.SYNC_CLOUD
        HearthSettingsDestination.KOReader -> Routes.KOREADER_HUB
        HearthSettingsDestination.Obsidian -> Routes.OBSIDIAN_SYNC
        HearthSettingsDestination.Vocabulary -> Routes.VOCABULARY_HUB
        HearthSettingsDestination.Dictionaries -> Routes.DICTIONARIES
        HearthSettingsDestination.LibraryDisplay -> Routes.LIBRARY_DISPLAY
        HearthSettingsDestination.HiddenBooks -> Routes.HIDDEN_BOOKS
        HearthSettingsDestination.Annotations -> Routes.ANNOTATIONS
        HearthSettingsDestination.Stats -> Routes.STATS
        HearthSettingsDestination.Achievements -> Routes.ACHIEVEMENTS
        HearthSettingsDestination.Appearance -> Routes.APPEARANCE
        HearthSettingsDestination.Accessibility -> Routes.ACCESSIBILITY
        HearthSettingsDestination.Playback -> Routes.PLAYBACK
        HearthSettingsDestination.About -> Routes.ABOUT
        HearthSettingsDestination.CrashLogs -> Routes.CRASH_LOGS
        HearthSettingsDestination.AudioEffects -> Routes.AUDIO_EFFECTS
    }

    private fun openReader(book: Book, annotation: ReaderAnnotation? = null) {
        val readerFormat = book.readerFormat()
        startActivity(
            when (readerFormat?.uppercase()) {
                "PDF" -> com.enve.app.ui.screens.PdfReaderActivity.createIntent(
                    context = this,
                    bookId = book.id,
                    bookSource = book.source,
                    connectionId = book.connectionId,
                    title = book.title,
                    author = book.author ?: "",
                    locator = annotation?.readerLocator(readerFormat) ?: book.epubLocator,
                ).apply { putExtra(com.enve.app.ui.screens.PdfReaderActivity.EXTRA_HEARTH_CHROME, true) }
                "CBZ", "CBX", "CBR" -> com.enve.app.ui.screens.ComicReaderActivity.createIntent(
                    context = this,
                    bookId = book.id,
                    bookSource = book.source,
                    connectionId = book.connectionId,
                    title = book.title,
                    author = book.author ?: "",
                    format = readerFormat,
                    locator = annotation?.readerLocator(readerFormat) ?: book.epubLocator,
                ).apply { putExtra(com.enve.app.ui.screens.ComicReaderActivity.EXTRA_HEARTH_CHROME, true) }
                else -> com.enve.app.ui.screens.EbookReaderActivity.createIntent(
                    context = this,
                    bookId = book.id,
                    bookSource = book.source,
                    connectionId = book.connectionId,
                    title = book.title,
                    author = book.author ?: "",
                    bookFormat = readerFormat,
                    epubLocator = annotation?.readerLocator(readerFormat) ?: book.epubLocator,
                    epubProgress = annotation?.totalProgression?.toFloat()?.coerceIn(0f, 1f)
                        ?: book.epubProgress
                        ?: book.readProgress,
                    lastReadTime = book.lastReadTime,
                ).apply { putExtra(com.enve.app.ui.screens.EbookReaderActivity.EXTRA_HEARTH_CHROME, true) }
            },
        )
    }

    private fun ReaderAnnotation.readerLocator(readerFormat: String?): String? {
        locatorJson?.takeIf { it.isNotBlank() }?.let { return it }
        val format = ReaderFormat.fromServerType(readerFormat)
        return when (format) {
            ReaderFormat.PDF -> pdfPage?.let { buildPageLocator(ReaderFormat.PDF, it) }
            ReaderFormat.CBZ, ReaderFormat.CBX, ReaderFormat.CBR -> cbzPage?.let { buildPageLocator(format, it) }
            else -> null
        }
    }

    override fun onResume() {
        super.onResume()
        if (skipNextResumeRefresh) {
            skipNextResumeRefresh = false
            return
        }
        val now = System.currentTimeMillis()
        if (now - lastRefreshAtMs < 500) return
        lastRefreshAtMs = now
        epdRefreshManager.requestTransitionRefresh(window.decorView)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleAuthCallbackIntent(intent)
        readWidgetIntent(intent)
    }

    private fun readWidgetIntent(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_OPEN_PLAYER, false) == true) openPlayerFromWidget.value = true
    }

    companion object {
        const val EXTRA_OPEN_PLAYER = "widget_open_player"
    }

    private fun handleAuthCallbackIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        authViewModel.handleAuthCallbackUri(uri)
    }
}
