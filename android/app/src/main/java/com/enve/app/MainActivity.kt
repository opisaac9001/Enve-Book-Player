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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import com.enve.core.listeningposition.ListeningPositionLink
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.enve.app.ui.components.CastButton

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    private var runtimeHost: RuntimeHost? = null
    internal class RuntimeHost(val runtime: com.enve.app.profiles.ActiveProfileRuntime) : androidx.lifecycle.ViewModelStoreOwner {
        override val viewModelStore = androidx.lifecycle.ViewModelStore()
        val factory = com.enve.app.profiles.ProfileViewModelFactory(runtime.component)
        val auth: AuthViewModel get() = androidx.lifecycle.ViewModelProvider(viewModelStore, factory)[AuthViewModel::class.java]
        var readerOpenJob: kotlinx.coroutines.Job? = null

        fun takeReaderOpenJob(): kotlinx.coroutines.Job? = readerOpenJob.also {
            readerOpenJob = null
            it?.cancel()
        }

        fun acceptsReaderRequest(active: com.enve.app.profiles.ActiveProfileRuntime?, state: com.enve.engine.profiles.ProfilesUiState): Boolean =
            active === runtime && !state.locked && !state.switching
    }
    private val openPlayerFromWidget = kotlinx.coroutines.flow.MutableStateFlow(false)
    private val positionLinkMessage = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    private val clubInvite = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    private val readerShortcut = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    private val incomingFiles = kotlinx.coroutines.flow.MutableStateFlow<List<android.net.Uri>>(emptyList())

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
        com.enve.app.automation.ReaderShortcuts.publish(this)
        readerShortcut.value = if (savedInstanceState == null) {
            intent.takeUnless { it.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0 }
                ?.let { com.enve.app.automation.ReaderShortcuts.request(this, it) }
        } else {
            savedInstanceState.getString("reader_shortcut")
        }
        if (savedInstanceState == null) readPositionLinkIntent(intent)
        if (savedInstanceState == null) readClubInvite(intent)
        else clubInvite.value = savedInstanceState.getString("clubs_invite")
        incomingFiles.value = if (savedInstanceState == null) {
            if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0) {
                com.enve.app.cloud.IncomingBookIntent.files(intent, "$packageName.fileprovider")
            } else emptyList()
        } else {
            savedInstanceState.getStringArrayList("incoming_books").orEmpty().map(android.net.Uri::parse)
        }

        lifecycleScope.launch {
            profiles.initialize()
        }

        setContent {
            val profileState by profiles.state.collectAsState()
            val active by profiles.activeRuntime.collectAsState()
            val runtime = active
            val appearance = runtime?.component?.preferencesFacade()
            val uiTextScale by (appearance?.uiTextScale ?: kotlinx.coroutines.flow.flowOf(1f)).collectAsState(initial = 1f)
            val hearthMode by (appearance?.themeMode ?: kotlinx.coroutines.flow.flowOf(HearthThemeMode.SYSTEM)).collectAsState(initial = HearthThemeMode.SYSTEM)
            val hearthOled by (appearance?.oledEnabled ?: kotlinx.coroutines.flow.flowOf(false)).collectAsState(initial = false)
            val hearthAccentHex by (appearance?.accentHex ?: kotlinx.coroutines.flow.flowOf("#F5921A")).collectAsState(initial = "#F5921A")
            val paletteStyle by (appearance?.paletteStyle ?: kotlinx.coroutines.flow.flowOf(com.enve.engine.theme.HearthPaletteStyle.PARCHMENT)).collectAsState(initial = com.enve.engine.theme.HearthPaletteStyle.PARCHMENT)
            val reduceMotion by (appearance?.reduceMotion ?: kotlinx.coroutines.flow.flowOf(false)).collectAsState(initial = false)
            val detectedEink = remember {
                val eink = com.enve.app.eink.EinkDetector(this@MainActivity).detect().isEink
                com.enve.engine.eink.EinkState.Inactive.copy(active = eink, monochrome = eink)
            }
            val eink by (runtime?.component?.einkFacade()?.state ?: kotlinx.coroutines.flow.flowOf(detectedEink)).collectAsState(initial = detectedEink)
            if (runtime == null || profileState.locked || profileState.switching) {
                com.enve.hearth.design.HearthTheme(
                    mode = hearthMode, oledEnabled = hearthOled,
                    accent = parseHexColor(hearthAccentHex) ?: EmberAccent,
                    paletteStyle = paletteStyle, uiTextScale = uiTextScale, reduceMotion = reduceMotion,
                    eink = com.enve.hearth.design.HearthEink(eink),
                ) {
                    val lightBars = !com.enve.hearth.design.Hearth.palette.isInk
                    SideEffect {
                        WindowInsetsControllerCompat(window, window.decorView).apply {
                            isAppearanceLightStatusBars = lightBars
                            isAppearanceLightNavigationBars = lightBars
                        }
                    }
                    if (profileState.switching) {
                        com.enve.hearth.profiles.HearthProfileTransitionScreen()
                    } else {
                        com.enve.hearth.profiles.HearthProfilePickerScreen(profiles, onSelected = {})
                    }
                }
                return@setContent
            }
            key(runtime.generation) {
                val sharedFiles by incomingFiles.collectAsState()
                LaunchedEffect(runtime.generation, sharedFiles) {
                    if (sharedFiles.isNotEmpty()) {
                        startActivity(com.enve.app.cloud.CloudImportActivity.incomingIntent(this@MainActivity, sharedFiles))
                        incomingFiles.value = emptyList()
                    }
                }
                val host = remember(runtime.generation) { RuntimeHost(runtime) }
                DisposableEffect(host) {
                    runtimeHost = host
                    runtime.component.einkManager().initialize()
                    val registration = profileLifecycle.register(runtime.profileId) {
                        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) {
                            host.takeReaderOpenJob()?.cancelAndJoin()
                            host.viewModelStore.clear()
                            host.factory.retire()
                            if (runtimeHost === host) runtimeHost = null
                        }
                    }
                    handleAuthCallbackIntent(intent)
                    onDispose {
                        val readerJob = host.takeReaderOpenJob()
                        host.viewModelStore.clear()
                        lifecycleScope.launch(kotlinx.coroutines.NonCancellable + kotlinx.coroutines.Dispatchers.Main.immediate) {
                            try {
                                readerJob?.cancelAndJoin()
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
            val playbackOpenProgress = runtime.component.playbackOpenProgressResolver()
            val epdRefreshManager = runtime.component.epdRefreshManager()
            val themeViewModel: ThemeViewModel = profileViewModel()
            val themeState by themeViewModel.themeState.collectAsState()
            val playbackConflict by playbackOpenProgress.pendingConflict.collectAsStateWithLifecycle()
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
            var libraryShortcutRequest by remember { mutableStateOf(false) }
            val shortcut by readerShortcut.collectAsState()
            LaunchedEffect(shortcut, runtime.generation) {
                val request = shortcut ?: return@LaunchedEffect
                classicInitialRoute = null
                if (request == com.enve.app.automation.ReaderShortcuts.CONTINUE &&
                    runtime.component.preferencesFacade().readingEnabled.first()) {
                    val library = runtime.component.library()
                    val key = runtime.component.lastOpenedBookStore().lastOpenedBookKey.first()
                    val last = key?.let { library.bookByKeyFlow(it).first() }
                        ?.takeIf { it.mediaType == com.enve.core.data.model.AppMediaType.EBOOK }
                    val book = last ?: library.continueBooks.first()
                        .filter { it.mediaType == com.enve.core.data.model.AppMediaType.EBOOK }
                        .maxByOrNull { it.lastReadTime }
                    if (book != null) openReader(book) else libraryShortcutRequest = true
                } else {
                    libraryShortcutRequest = true
                }
                readerShortcut.value = null
            }

            var resumeHearthInSettings by remember { mutableStateOf(false) }
            val hearthState = rememberSaveableStateHolder()
            if (classicInitialRoute == null) {
                val widgetPlayerRequest by openPlayerFromWidget.collectAsState()
                val positionLinkRequest by positionLinkMessage.collectAsState()
                val clubInviteRequest by clubInvite.collectAsState()
                val profileRole = profileState.profiles.firstOrNull { it.id == runtime.profileId }?.role
                val clubs = remember(runtime.generation, profileRole) {
                    if (profileRole == com.enve.core.data.local.FamilyProfileRole.CHILD) null else runtime.component.clubs()
                }
                hearthState.SaveableStateProvider("hearth") {
                    HearthRoot(
                        imageLoader = runtime.component.imageLoader(),
                        onOpenProfiles = if (profileState.enabled) ({ classicInitialRoute = Routes.PROFILES }) else null,
                        profileName = profileState.profiles.firstOrNull { it.id == runtime.profileId }?.name,
                        initialShowSettings = resumeHearthInSettings,
                        showPlayerRequest = widgetPlayerRequest,
                        showLibraryRequest = libraryShortcutRequest,
                        onLibraryRequestConsumed = { libraryShortcutRequest = false },
                        onPlayerRequestConsumed = { openPlayerFromWidget.value = false },
                        positionLinkRequest = positionLinkRequest,
                        onPositionLinkConsumed = { positionLinkMessage.value = null },
                        clubs = clubs,
                        clubBooks = if (clubs?.available == true) runtime.component.library().allBooks else null,
                        clubInviteRequest = clubInviteRequest,
                        onClubInviteConsumed = { clubInvite.value = null },
                        onOpenEbookPassage = { book, query -> openReader(book, searchQuery = query) },
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
                }
            } else {
                com.enve.hearth.design.HearthTheme(
                    mode = hearthMode, accent = bridgedAccent, oledEnabled = hearthOled,
                    paletteStyle = paletteStyle, uiTextScale = uiTextScale, reduceMotion = reduceMotion,
                    eink = com.enve.hearth.design.HearthEink(eink),
                ) {
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
        HearthSettingsDestination.SettingsBackup -> Routes.SETTINGS_BACKUP
        HearthSettingsDestination.SyncCloud -> Routes.SYNC_CLOUD
        HearthSettingsDestination.KOReader -> Routes.KOREADER_HUB
        HearthSettingsDestination.Obsidian -> Routes.OBSIDIAN_SYNC
        HearthSettingsDestination.Readwise -> Routes.READWISE
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

    private fun openReader(book: Book, annotation: ReaderAnnotation? = null, searchQuery: String? = null) {
        val host = runtimeHost ?: return
        if (!host.acceptsReaderRequest(profiles.activeRuntime.value, profiles.state.value)) return
        host.takeReaderOpenJob()
        val runtime = host.runtime
        host.readerOpenJob = lifecycleScope.launch {
            val resolved = if (book.readerFormat() == null) {
                try {
                    runtime.component.library().bookDetail(book) ?: book
                } catch (error: kotlinx.coroutines.CancellationException) {
                    throw error
                } catch (error: Exception) {
                    if (runtimeHost === host && host.acceptsReaderRequest(profiles.activeRuntime.value, profiles.state.value)) {
                        android.widget.Toast.makeText(this@MainActivity, "Couldn't open this book. Check the server connection and try again.", android.widget.Toast.LENGTH_LONG).show()
                    }
                    return@launch
                }
            } else book
            if (runtimeHost !== host || !host.acceptsReaderRequest(profiles.activeRuntime.value, profiles.state.value)) return@launch
            val readerFormat = resolved.readerFormat()
            startActivity(
                when (readerFormat?.uppercase()) {
                    "PDF" -> com.enve.app.ui.screens.PdfReaderActivity.createIntent(
                        context = this@MainActivity,
                        bookId = resolved.id,
                        bookSource = resolved.source,
                        connectionId = resolved.connectionId,
                        title = resolved.title,
                        author = resolved.author ?: "",
                        locator = annotation?.readerLocator(readerFormat) ?: resolved.epubLocator,
                    )
                    "CBZ", "CBX", "CBR" -> com.enve.app.ui.screens.ComicReaderActivity.createIntent(
                        context = this@MainActivity,
                        bookId = resolved.id,
                        bookSource = resolved.source,
                        connectionId = resolved.connectionId,
                        title = resolved.title,
                        author = resolved.author ?: "",
                        format = readerFormat,
                        locator = annotation?.readerLocator(readerFormat) ?: resolved.epubLocator,
                    )
                    else -> com.enve.app.ui.screens.EbookReaderActivity.createIntent(
                        context = this@MainActivity,
                        bookId = resolved.id,
                        bookSource = resolved.source,
                        connectionId = resolved.connectionId,
                        title = resolved.title,
                        author = resolved.author ?: "",
                        bookFormat = readerFormat,
                        epubLocator = annotation?.readerLocator(readerFormat) ?: resolved.epubLocator,
                        epubProgress = annotation?.totalProgression?.toFloat()?.coerceIn(0f, 1f)
                            ?: resolved.epubProgress
                            ?: resolved.readProgress,
                        lastReadTime = resolved.lastReadTime,
                        searchQuery = searchQuery,
                    )
                },
            )
        }
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
        readPositionLinkIntent(intent)
        readClubInvite(intent)
        com.enve.app.cloud.IncomingBookIntent.files(intent, "$packageName.fileprovider")
            .takeIf { it.isNotEmpty() }?.let { incomingFiles.value = it }
        com.enve.app.automation.ReaderShortcuts.request(this, intent)
            ?.let { readerShortcut.value = it }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("reader_shortcut", readerShortcut.value)
        outState.putString("clubs_invite", clubInvite.value)
        outState.putStringArrayList("incoming_books", ArrayList(incomingFiles.value.map(android.net.Uri::toString)))
        super.onSaveInstanceState(outState)
    }

    private fun readWidgetIntent(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_OPEN_PLAYER, false) == true) openPlayerFromWidget.value = true
    }

    private fun readClubInvite(intent: Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme != "enve-book" || uri.host != "club" || uri.path != "/join" ||
            uri.userInfo != null || uri.port != -1 || uri.fragment != null || uri.queryParameterNames != setOf("code")) return
        val code = uri.getQueryParameters("code").singleOrNull() ?: return
        if (code.matches(Regex("[A-HJ-NP-Z2-9]{10}"))) clubInvite.value = code
    }

    private fun readPositionLinkIntent(intent: Intent?) {
        intent?.dataString?.let(ListeningPositionLink::message)?.let { positionLinkMessage.value = it }
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
