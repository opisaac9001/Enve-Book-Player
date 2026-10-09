package com.enve.app

import com.enve.app.profiles.ProfileActivityBinding
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.WindowInsetsControllerCompat
import com.enve.hearth.shell.profileViewModel
import com.enve.app.eink.EpdRefreshManager
import com.enve.app.ui.EnveApp
import com.enve.app.ui.Routes
import com.enve.app.ui.readerFormat
import com.enve.app.ui.screens.ReaderFormat
import com.enve.app.ui.screens.ProgressConflictDialog
import com.enve.app.ui.screens.buildPageLocator
import com.enve.app.ui.theme.AppTheme
import com.enve.app.ui.theme.EnveTheme
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import com.enve.engine.theme.HearthThemeMode
import com.enve.hearth.design.EmberAccent
import com.enve.hearth.design.parseHexColor
import com.enve.hearth.shell.HearthRoot
import com.enve.hearth.settings.HearthSettingsDestination
import com.enve.app.ui.auth.AuthViewModel
import com.enve.app.ui.auth.OpdsAuthBrowserActivity
import com.enve.app.viewmodel.ThemeViewModel
import com.enve.app.viewmodel.ProgressConflictPrompt
import com.enve.app.playback.PlaybackOpenProgressResolver
import com.enve.app.playback.PlaybackProgressConflictChoice
import androidx.lifecycle.lifecycleScope
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.enve.app.ui.components.CastButton

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    private var runtimeHost: RuntimeHost? = null
    private class RuntimeHost(val runtime: com.enve.app.profiles.ActiveProfileRuntime) : androidx.lifecycle.ViewModelStoreOwner {
        override val viewModelStore = androidx.lifecycle.ViewModelStore()
        val factory = com.enve.app.profiles.ProfileViewModelFactory(runtime.component)
        val auth: AuthViewModel get() = androidx.lifecycle.ViewModelProvider(viewModelStore, factory)[AuthViewModel::class.java]
    }
    private val openPlayerFromWidget = kotlinx.coroutines.flow.MutableStateFlow(false)

    @Inject
    lateinit var profiles: com.enve.app.profiles.ProfileSwitchCoordinator

    @Inject
    lateinit var profileLifecycle: com.enve.app.profiles.ProfileLifecycleRegistry

    private var skipNextResumeRefresh: Boolean = true
    private var lastRefreshAtMs: Long = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        val splashScreen = installSplashScreen()
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        readWidgetIntent(intent)

        lifecycleScope.launch {
            profiles.initialize()
        }

        setContent {
            val profileState by profiles.state.collectAsState()
            val active by profiles.activeRuntime.collectAsState()
            val runtime = active
            if (runtime == null || profileState.locked || profileState.switching) {
                com.enve.hearth.design.HearthTheme {
                    if (!profileState.switching) {
                        com.enve.hearth.profiles.HearthProfilePickerScreen(profiles, onSelected = {})
                    }
                }
                return@setContent
            }
            key(runtime.generation) {
                val host = remember(runtime.generation) { RuntimeHost(runtime) }
                DisposableEffect(host) {
                    runtimeHost = host
                    runtime.component.einkManager().initialize()
                    val registration = profileLifecycle.register(runtime.profileId) {
                        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) {
                            host.viewModelStore.clear()
                            host.factory.retire()
                            if (runtimeHost === host) runtimeHost = null
                        }
                    }
                    handleAuthCallbackIntent(intent)
                    onDispose {
                        host.viewModelStore.clear()
                        lifecycleScope.launch(kotlinx.coroutines.NonCancellable + kotlinx.coroutines.Dispatchers.Main.immediate) {
                            try {
                                host.factory.retire()
                            } finally {
                                registration.close()
                            }
                        }
                        if (runtimeHost === host) runtimeHost = null
                    }
                }
                LaunchedEffect(host) {
                    delay(5_000)
                    if (runtime.component.preferences().autoSyncOnLaunch.first()) runtime.component.recentlyPlayedSyncService().syncOnLaunch()
                }
                CompositionLocalProvider(
                    com.enve.hearth.shell.LocalProfileViewModelFactory provides host.factory,
                    androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner provides host,
                ) {
            val hearthPreferences = runtime.component.preferencesFacade()
            val playbackOpenProgress = runtime.component.playbackOpenProgressResolver()
            val epdRefreshManager = runtime.component.epdRefreshManager()
            val uiTextScale by hearthPreferences.uiTextScale.collectAsState(initial = 1f)
            val hearthMode by hearthPreferences.themeMode.collectAsState(initial = HearthThemeMode.SYSTEM)
            val hearthOled by hearthPreferences.oledEnabled.collectAsState(initial = false)
            val hearthAccentHex by hearthPreferences.accentHex.collectAsState(initial = "#F5921A")
            val themeViewModel: ThemeViewModel = profileViewModel()
            val themeState by themeViewModel.themeState.collectAsState()
            val playbackConflict by playbackOpenProgress.pendingConflict.collectAsState()
            val hearthDark = when (hearthMode) {
                HearthThemeMode.SYSTEM -> isSystemInDarkTheme()
                HearthThemeMode.INK -> true
                HearthThemeMode.PAPER -> false
            }
            val lightSystemBars = themeState.einkProfile.monochrome || !hearthDark
            SideEffect {
                WindowInsetsControllerCompat(window, window.decorView).apply {
                    isAppearanceLightStatusBars = lightSystemBars
                    isAppearanceLightNavigationBars = lightSystemBars
                }
            }
            val bridgedTheme = when {
                themeState.einkProfile.monochrome -> themeState.effectiveAppTheme
                !hearthDark -> AppTheme.PAPER_WHITE
                hearthOled -> AppTheme.OLED
                else -> AppTheme.DARK
            }
            val bridgedAccent = remember(hearthAccentHex) { parseHexColor(hearthAccentHex) ?: EmberAccent }

            var classicInitialRoute by remember { mutableStateOf<String?>(null) }
            var downloadedBookRequest by remember { mutableStateOf<Book?>(null) }

            var resumeHearthInSettings by remember { mutableStateOf(false) }
            if (classicInitialRoute == null) {
                val widgetPlayerRequest by openPlayerFromWidget.collectAsState()
                HearthRoot(
                    imageLoader = runtime.component.imageLoader(),
                    onOpenProfiles = if (profileState.enabled) ({ classicInitialRoute = Routes.PROFILES }) else null,
                    profileName = profileState.profiles.firstOrNull { it.id == runtime.profileId }?.name,
                    initialShowSettings = resumeHearthInSettings,
                    showPlayerRequest = widgetPlayerRequest,
                    onPlayerRequestConsumed = { openPlayerFromWidget.value = false },
                    openBookRequest = downloadedBookRequest,
                    onBookRequestConsumed = { downloadedBookRequest = null },
                    playerTopAction = { CastButton(Modifier.size(48.dp)) },
                    onOpdsAuthorize = { connectionId, methodType, authorizeUrl ->
                        startActivity(
                            Intent(this@MainActivity, OpdsAuthBrowserActivity::class.java)
                                .putExtra(OpdsAuthBrowserActivity.EXTRA_CONNECTION_ID, connectionId)
                                .putExtra(OpdsAuthBrowserActivity.EXTRA_METHOD_TYPE, methodType)
                                .putExtra(OpdsAuthBrowserActivity.EXTRA_AUTHORIZE_URL, authorizeUrl),
                        )
                    },
                    playerOverlay = {
                        playbackConflict?.let { conflict ->
                            EnveTheme(
                                appTheme = bridgedTheme,
                                themeColor = bridgedAccent,
                                dynamicBackgroundEnabled = false,
                                einkProfile = themeState.einkProfile,
                            ) {
                                ProgressConflictDialog(
                                    prompt = ProgressConflictPrompt(
                                        localPercentage = conflict.localPercentage,
                                        localUpdatedAt = conflict.localUpdatedAt,
                                        remotePercentage = conflict.remotePercentage,
                                        remoteUpdatedAt = conflict.remoteUpdatedAt,
                                        remoteSource = conflict.remoteSource,
                                    ),
                                    onChooseLocal = {
                                        playbackOpenProgress.resolveConflict(PlaybackProgressConflictChoice.LOCAL)
                                    },
                                    onChooseRemote = {
                                        playbackOpenProgress.resolveConflict(PlaybackProgressConflictChoice.REMOTE)
                                    },
                                    onDecideLater = {
                                        playbackOpenProgress.resolveConflict(PlaybackProgressConflictChoice.LATER)
                                    },
                                )
                            }
                        }
                    },
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
                com.enve.hearth.design.HearthUiTextScale(uiTextScale) {
                    EnveTheme(
                        appTheme = bridgedTheme,
                        themeColor = bridgedAccent,
                        dynamicBackgroundEnabled = false,
                        einkProfile = themeState.einkProfile,
                    ) {
                        EnveApp(
                            epdRefreshManager = epdRefreshManager,
                            profilesFacade = profiles,
                            initialRoute = classicInitialRoute,
                            onExitInitialRoute = { classicInitialRoute = null },
                            onOpenDownloadedBook = { book ->
                                downloadedBookRequest = book
                                resumeHearthInSettings = false
                                classicInitialRoute = null
                            },
                        )
                    }
                }
            }
                }
            }
        }
    }

    private fun HearthSettingsDestination.toRoute(): String = when (this) {
        HearthSettingsDestination.Profiles -> Routes.PROFILES
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
                )
                "CBZ", "CBX", "CBR" -> com.enve.app.ui.screens.ComicReaderActivity.createIntent(
                    context = this,
                    bookId = book.id,
                    bookSource = book.source,
                    connectionId = book.connectionId,
                    title = book.title,
                    author = book.author ?: "",
                    format = readerFormat,
                    locator = annotation?.readerLocator(readerFormat) ?: book.epubLocator,
                )
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
                )
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
        runtimeHost?.runtime?.component?.epdRefreshManager()?.requestTransitionRefresh(window.decorView)
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) runtimeHost?.runtime?.component?.sessions()?.flush()
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
        val host = runtimeHost ?: return
        if (profiles.state.value.locked || profiles.state.value.switching) return
        val profileId = intent.getStringExtra(ProfileActivityBinding.EXTRA_PROFILE_ID)
        val generation = intent.getLongExtra(ProfileActivityBinding.EXTRA_GENERATION, -1L)
        if (profileId != null) {
            if (profileId != host.runtime.profileId || generation != host.runtime.generation) return
        } else if (profiles.state.value.enabled) {
            return
        }
        host.auth.handleAuthCallbackUri(uri)
    }
}
