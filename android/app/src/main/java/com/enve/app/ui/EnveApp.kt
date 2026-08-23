package com.enve.app.ui

import android.content.Intent
import android.os.Build
import android.net.Uri
import androidx.activity.compose.BackHandler
import com.enve.app.BuildConfig
import com.enve.core.data.model.BookSource
import androidx.compose.animation.*
import com.enve.app.ui.components.EnveAnimations
import com.enve.app.ui.auth.AuthViewModel
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.*
import com.enve.core.data.model.Book
import com.enve.app.eink.EpdRefreshManager
import com.enve.app.ui.screens.*
import com.enve.hearth.storyalign.HearthStoryAlignScreen
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.*

object Routes {
    const val STATS = "stats"
    const val LIBRARY_CONNECTIONS = "settings/connections"
    const val SERVER_MANAGEMENT = "settings/serverManagement"
    const val SERVER_TOOLS = "settings/serverTools/{connectionId}"
    fun serverTools(connectionId: String) = "settings/serverTools/${Uri.encode(connectionId)}"
    const val LIBRARY_HUB = "settings/libraryHub"
    const val KOMGA_HUB = "settings/komgaHub"
    const val SILO_HUB = "settings/siloHub"
    const val STORYTELLER_HUB = "settings/storytellerHub/{connectionId}"
    fun storytellerHub(connectionId: String) = "settings/storytellerHub/${Uri.encode(connectionId)}"
    const val KOMGA_USERS = "settings/komgaHub/users/{connectionId}"
    const val KOMGA_LIBRARIES = "settings/komgaHub/libraries/{connectionId}"
    const val KOMGA_COLLECTIONS = "settings/komgaHub/collections/{connectionId}"
    const val KOMGA_READLISTS = "settings/komgaHub/readlists/{connectionId}"
    const val KOMGA_SERVER_INFO = "settings/komgaHub/server/{connectionId}"
    const val KOMGA_ANNOUNCEMENTS = "settings/komgaHub/announcements/{connectionId}"
    const val KOMGA_HISTORY = "settings/komgaHub/history/{connectionId}"
    const val KOMGA_API_KEYS = "settings/komgaHub/apikeys/{connectionId}"
    fun komgaUsers(id: String) = "settings/komgaHub/users/$id"
    fun komgaLibraries(id: String) = "settings/komgaHub/libraries/$id"
    fun komgaCollections(id: String) = "settings/komgaHub/collections/$id"
    fun komgaReadLists(id: String) = "settings/komgaHub/readlists/$id"
    fun komgaServerInfo(id: String) = "settings/komgaHub/server/$id"
    fun komgaAnnouncements(id: String) = "settings/komgaHub/announcements/$id"
    fun komgaHistory(id: String) = "settings/komgaHub/history/$id"
    fun komgaApiKeys(id: String) = "settings/komgaHub/apikeys/$id"
    const val HARDCOVER_HUB = "settings/hardcoverHub"
    const val METADATA_HUB = "settings/metadataHub"
    const val ACHIEVEMENTS = "settings/achievements"
    const val STORYALIGN_HUB = "settings/storyAlign"
    const val STORYALIGN_STUDIO = "settings/storyAlignStudio"
    const val EINK_HUB = "settings/einkHub"
    const val QUICK_CONNECT = "quickConnect"
    const val SERVICE_LOGIN = "settings/serviceLogin/{source}?connectionId={connectionId}&prefillUrl={prefillUrl}&autoSso={autoSso}"
    const val APPEARANCE = "settings/appearance"
    const val CUSTOM_FONTS = "settings/customFonts"
    const val ACCESSIBILITY = "settings/accessibility"
    const val HIDDEN_BOOKS = "settings/hiddenBooks"
    const val DOWNLOADS = "settings/downloads"
    const val STORAGE = "settings/storage"
    const val SYNC_CLOUD = "settings/syncCloud"
    const val KOREADER_HUB = "settings/koreaderHub"
    const val OBSIDIAN_SYNC = "settings/obsidianSync"
    const val VOCABULARY_HUB = "settings/vocabulary"
    const val VOCABULARY_STUDY = "settings/vocabulary/study"
    const val VOCABULARY_SETTINGS = "settings/vocabulary/settings"
    const val DICTIONARIES = "settings/dictionaries"
    const val PLAYBACK = "settings/playback"
    const val LIBRARY_DISPLAY = "settings/libraryDisplay"
    const val ANNOTATIONS = "annotations"
    const val ABOUT = "settings/about"
    const val CRASH_LOGS = "settings/crashLogs"
    const val TIP_JAR = "settings/tipJar"
    const val AUDIO_EFFECTS = "settings/audioEffects"

    fun serviceLogin(
        source: com.enve.core.data.model.BookSource,
        connectionId: String? = null,
        prefillUrl: String? = null,
        autoSso: Boolean = false,
    ): String {
        val base = "settings/serviceLogin/${source.name}"
        val params = buildList {
            connectionId?.let { add("connectionId=${Uri.encode(it)}") }
            prefillUrl?.let { add("prefillUrl=${Uri.encode(it)}") }
            if (autoSso) add("autoSso=true")
        }
        return if (params.isEmpty()) base else "$base?${params.joinToString("&")}"
    }
}

@Composable
fun EnveApp(
    epdRefreshManager: EpdRefreshManager? = null,
    initialRoute: String? = null,
    onExitInitialRoute: () -> Unit = {},
) {
    val navController = rememberNavController()
    val authViewModel: AuthViewModel = hiltViewModel()
    val libraryViewModel: LibraryViewModel = hiltViewModel()
    val playerViewModel: PlayerViewModel = hiltViewModel()
    val statsViewModel: StatsViewModel = hiltViewModel()
    val themeViewModel: ThemeViewModel = hiltViewModel()
    val authState by authViewModel.state.collectAsState()
        val context = LocalContext.current
        val rootView = LocalView.current

        val reportIssue: () -> Unit = {
            val mailTo = Uri.parse("mailto:support@enveapp.io")
            val intent = Intent(Intent.ACTION_SENDTO, mailTo).apply {
                putExtra(Intent.EXTRA_SUBJECT, "Enve Android Issue Report")
                putExtra(
                    Intent.EXTRA_TEXT,
                    "Please describe the issue:\n\n\nApp version: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})\nAndroid: ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})\nDevice: ${Build.MANUFACTURER} ${Build.MODEL}"
                )
            }
            runCatching {
                context.startActivity(Intent.createChooser(intent, "Report Issue"))
            }
        }

        val openWebsite: () -> Unit = {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://enveapp.io"))
            runCatching { context.startActivity(intent) }
        }

        val openPrivacyPolicy: () -> Unit = {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://enveapp.io/privacy"))
            runCatching { context.startActivity(intent) }
        }

        val openTipJar: () -> Unit = { navController.navigate(Routes.TIP_JAR) }

        val rateApp: () -> Unit = {
            val packageName = context.packageName
            val marketIntent = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$packageName"))
            val webIntent = Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$packageName"))
            runCatching { context.startActivity(marketIntent) }
                .onFailure { runCatching { context.startActivity(webIntent) } }
        }

    val playerState by playerViewModel.state.collectAsState()
    val statsState by statsViewModel.state.collectAsState()
    val themeState by themeViewModel.themeState.collectAsState()
    val downloadsHubViewModel: DownloadsHubViewModel = hiltViewModel()
    val storageHubViewModel: StorageHubViewModel = hiltViewModel()
    val downloadsHubState by downloadsHubViewModel.state.collectAsState()
    val storageHubState by storageHubViewModel.state.collectAsState()
    val navigationAnimationsEnabled = themeState.effectiveAppTheme != com.enve.app.ui.theme.AppTheme.EINK

    if (!authState.isInitialized) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(EnveTheme.colors.background),
            contentAlignment = Alignment.Center,
        ) {
            CircularProgressIndicator(color = EnveTheme.colors.accent)
        }
        return
    }

    val startDestination = initialRoute ?: Routes.QUICK_CONNECT

    val bridgeMode = initialRoute != null
    val goBack: () -> Unit = {
        if (!navController.popBackStack() && bridgeMode) {
            onExitInitialRoute()
        }
    }

    BackHandler(enabled = bridgeMode) {
        goBack()
    }

    CompositionLocalProvider(
        com.enve.app.ui.theme.LocalEpdRefreshManager provides epdRefreshManager,
    ) {
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = EnveTheme.colors.background,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
    ) { innerPadding ->
        NavHost(
            navController = navController,
            startDestination = startDestination,
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            enterTransition = { if (navigationAnimationsEnabled) EnveAnimations.enterSlideFade() else EnterTransition.None },
            exitTransition = { if (navigationAnimationsEnabled) EnveAnimations.exitSlideFade() else ExitTransition.None },
            popEnterTransition = { if (navigationAnimationsEnabled) EnveAnimations.popEnterSlideFade() else EnterTransition.None },
            popExitTransition = { if (navigationAnimationsEnabled) EnveAnimations.popExitSlideFade() else ExitTransition.None },
        ) {
            composable(Routes.STATS) {
                StatsScreen(
                    state = statsState,
                    onMediaTypeChange = { statsViewModel.setMediaType(it) },
                    onRefresh = { statsViewModel.refresh() },
                    onBack = goBack,
                )
            }

            composable(Routes.ANNOTATIONS) {
                com.enve.app.ui.screens.AnnotationsScreen(
                    onBack = goBack,
                )
            }

            composable(Routes.ACHIEVEMENTS) {
                AchievementsScreen(
                    state = statsState,
                    onBack = goBack,
                    onRefresh = { statsViewModel.refresh() },
                    onWeeklyGoalChange = { statsViewModel.setWeeklyGoal(it) },
                )
            }

            composable(Routes.LIBRARY_HUB) {
                LibraryManagementHubScreen(
                    viewModel = libraryViewModel,
                    onBack = goBack,
                    onNavigateToConnections = { navController.navigate(Routes.QUICK_CONNECT) },
                )
            }

            composable(Routes.SERVER_MANAGEMENT) {
                ServerManagementHubScreen(
                    onBack = goBack,
                    onNavigateToConnections = { navController.navigate(Routes.QUICK_CONNECT) },
                    onOpenServerTools = { connectionId -> navController.navigate(Routes.serverTools(connectionId)) },
                )
            }

            composable(Routes.SERVER_TOOLS) {
                ServerToolsScreen(
                    onBack = goBack,
                    onOpenAdmin = { source, connectionId ->
                        when (source) {
                            BookSource.KOMGA -> navController.navigate(Routes.KOMGA_HUB)
                            BookSource.SILO -> navController.navigate(Routes.SILO_HUB)
                            BookSource.STORYTELLER -> navController.navigate(Routes.storytellerHub(connectionId))
                            else -> Unit
                        }
                    },
                )
            }

            composable(Routes.HARDCOVER_HUB) {
                HardcoverHubScreen(
                    onBack = goBack,
                )
            }

            composable(Routes.METADATA_HUB) {
                MetadataHubScreen(
                    onBack = goBack,
                )
            }

            composable(Routes.STORYALIGN_HUB) {
                val context = LocalContext.current
                StoryAlignHubScreen(
                    onBack = goBack,
                    onConnectStoryteller = { navController.navigate(Routes.serviceLogin(BookSource.STORYTELLER)) },
                    onManageServers = { navController.navigate(Routes.SERVER_MANAGEMENT) },
                    onOpenBook = { book ->
                        context.startActivity(
                            EbookReaderActivity.createIntent(
                                context = context,
                                bookId = book.id,
                                bookSource = book.source,
                                connectionId = book.connectionId,
                                title = book.title,
                                author = book.author ?: "",
                                bookFormat = book.readerFormat() ?: "READALOUD",
                                epubLocator = book.epubLocator,
                                epubProgress = book.epubProgress ?: book.readProgress,
                                lastReadTime = book.lastReadTime,
                            )
                        )
                    },
                )
            }

            composable(Routes.STORYALIGN_STUDIO) {
                HearthStoryAlignScreen(onBack = goBack)
            }

            composable(Routes.KOMGA_HUB) {
                KomgaHubScreen(
                    authViewModel = authViewModel,
                    onBack = goBack,
                    onOpenUsers = { id -> navController.navigate(Routes.komgaUsers(id)) },
                    onOpenLibraries = { id -> navController.navigate(Routes.komgaLibraries(id)) },
                    onOpenCollections = { id -> navController.navigate(Routes.komgaCollections(id)) },
                    onOpenReadLists = { id -> navController.navigate(Routes.komgaReadLists(id)) },
                    onOpenServerInfo = { id -> navController.navigate(Routes.komgaServerInfo(id)) },
                    onOpenAnnouncements = { id -> navController.navigate(Routes.komgaAnnouncements(id)) },
                    onOpenHistory = { id -> navController.navigate(Routes.komgaHistory(id)) },
                    onOpenApiKeys = { id -> navController.navigate(Routes.komgaApiKeys(id)) },
                )
            }

            composable(Routes.SILO_HUB) {
                SiloAdminHubScreen(
                    onBack = goBack,
                    onConnectSilo = { navController.navigate(Routes.serviceLogin(BookSource.SILO)) },
                )
            }

            composable(
                route = Routes.STORYTELLER_HUB,
                arguments = listOf(androidx.navigation.navArgument("connectionId") { type = androidx.navigation.NavType.StringType }),
            ) {
                StorytellerHubScreen(
                    onBack = goBack,
                    onConnectStoryteller = { navController.navigate(Routes.serviceLogin(BookSource.STORYTELLER)) },
                )
            }

            composable(
                route = Routes.KOMGA_USERS,
                arguments = listOf(androidx.navigation.navArgument("connectionId") { type = androidx.navigation.NavType.StringType }),
            ) {
                com.enve.app.ui.screens.komga.KomgaUsersScreen(onBack = goBack)
            }
            composable(
                route = Routes.KOMGA_LIBRARIES,
                arguments = listOf(androidx.navigation.navArgument("connectionId") { type = androidx.navigation.NavType.StringType }),
            ) {
                com.enve.app.ui.screens.komga.KomgaLibrariesScreen(onBack = goBack)
            }
            composable(
                route = Routes.KOMGA_COLLECTIONS,
                arguments = listOf(androidx.navigation.navArgument("connectionId") { type = androidx.navigation.NavType.StringType }),
            ) {
                com.enve.app.ui.screens.komga.KomgaCollectionsScreen(onBack = goBack)
            }
            composable(
                route = Routes.KOMGA_READLISTS,
                arguments = listOf(androidx.navigation.navArgument("connectionId") { type = androidx.navigation.NavType.StringType }),
            ) {
                com.enve.app.ui.screens.komga.KomgaReadListsScreen(onBack = goBack)
            }
            composable(
                route = Routes.KOMGA_SERVER_INFO,
                arguments = listOf(androidx.navigation.navArgument("connectionId") { type = androidx.navigation.NavType.StringType }),
            ) {
                com.enve.app.ui.screens.komga.KomgaServerInfoScreen(onBack = goBack)
            }
            composable(
                route = Routes.KOMGA_ANNOUNCEMENTS,
                arguments = listOf(androidx.navigation.navArgument("connectionId") { type = androidx.navigation.NavType.StringType }),
            ) {
                com.enve.app.ui.screens.komga.KomgaAnnouncementsScreen(onBack = goBack)
            }
            composable(
                route = Routes.KOMGA_HISTORY,
                arguments = listOf(androidx.navigation.navArgument("connectionId") { type = androidx.navigation.NavType.StringType }),
            ) {
                com.enve.app.ui.screens.komga.KomgaHistoryScreen(onBack = goBack)
            }
            composable(
                route = Routes.KOMGA_API_KEYS,
                arguments = listOf(androidx.navigation.navArgument("connectionId") { type = androidx.navigation.NavType.StringType }),
            ) {
                com.enve.app.ui.screens.komga.KomgaApiKeysScreen(onBack = goBack)
            }

            composable(Routes.LIBRARY_CONNECTIONS) {
                LibraryConnectionsScreen(
                    authState = authState,
                    authViewModel = authViewModel,
                    onBack = goBack,
                    onNavigateToServiceLogin = { source, connectionId ->
                        navController.navigate(Routes.serviceLogin(source, connectionId))
                    },
                    onSourceChange = { authViewModel.setSelectedSource(it) },
                    onServerUrlChange = { authViewModel.updateServerUrl(it) },
                    onUsernameChange = { authViewModel.updateUsername(it) },
                    onPasswordChange = { authViewModel.updatePassword(it) },
                    onLogin = { authViewModel.login() },
                    onLoginWithToken = { token -> authViewModel.loginWithToken(token) },
                    onStartOidcLogin = { authViewModel.startOidcLogin() },
                    onConsumeBrowserAuthUrl = { authViewModel.consumeBrowserAuthUrl() },
                    onLogout = { authViewModel.logout() },
                    onNavigateToKomgaHub = {
                        navController.navigate(Routes.KOMGA_HUB)
                    },
                    onNavigateToSiloHub = {
                        navController.navigate(Routes.SILO_HUB)
                    },
                    onNavigateToServerManagement = {
                        navController.navigate(Routes.SERVER_MANAGEMENT)
                    },
                )
            }

            composable(Routes.QUICK_CONNECT) {
                val quickConnectState by authViewModel.quickConnect.collectAsState()
                QuickConnectScreen(
                    quickConnect = quickConnectState,
                    onBack = goBack,
                    onProbe = { authViewModel.quickConnect(it) },
                    onConsumeResult = { authViewModel.consumeQuickConnectResult() },
                    onNavigateToManual = { navController.navigate(Routes.LIBRARY_CONNECTIONS) },
                    onNavigateToServiceLogin = { source, url, autoSso ->
                        navController.navigate(Routes.serviceLogin(source = source, prefillUrl = url, autoSso = autoSso))
                    },
                )
            }

            composable(
                route = Routes.SERVICE_LOGIN,
                arguments = listOf(
                    androidx.navigation.navArgument("source") { type = androidx.navigation.NavType.StringType },
                    androidx.navigation.navArgument("connectionId") {
                        type = androidx.navigation.NavType.StringType
                        nullable = true
                        defaultValue = null
                    },
                    androidx.navigation.navArgument("prefillUrl") {
                        type = androidx.navigation.NavType.StringType
                        nullable = true
                        defaultValue = null
                    },
                    androidx.navigation.navArgument("autoSso") {
                        type = androidx.navigation.NavType.BoolType
                        defaultValue = false
                    },
                ),
            ) { backStackEntry ->
                val sourceName = backStackEntry.arguments?.getString("source") ?: ""
                val source = runCatching {
                    com.enve.core.data.model.BookSource.valueOf(sourceName)
                }.getOrElse { com.enve.core.data.model.BookSource.GRIMMORY }
                val connectionId = backStackEntry.arguments?.getString("connectionId")
                val prefillUrl = backStackEntry.arguments?.getString("prefillUrl")
                val autoSso = backStackEntry.arguments?.getBoolean("autoSso") ?: false

                var loginAttempted by remember(sourceName) { mutableStateOf(false) }

                var epochAtOpen by remember(sourceName) { mutableStateOf(authState.loginEpoch) }

                LaunchedEffect(sourceName, connectionId) {
                    if (connectionId.isNullOrBlank()) {
                        authViewModel.setSelectedSource(source)
                        if (!prefillUrl.isNullOrBlank()) authViewModel.updateServerUrl(prefillUrl)
                        if (autoSso) {
                            authViewModel.updateAuthMode(com.enve.core.data.model.ConnectionAuthMode.SSO)
                            epochAtOpen = authState.loginEpoch
                            loginAttempted = true
                            kotlinx.coroutines.delay(450)
                            authViewModel.startOidcLogin()
                        }
                    } else {
                        authViewModel.prepareConnectionEdit(connectionId)
                    }
                }

                LaunchedEffect(authState.loginEpoch) {
                    if (loginAttempted && authState.loginEpoch > epochAtOpen) {
                        if (source == com.enve.core.data.model.BookSource.LOCAL) {
                            onExitInitialRoute()
                        } else {
                            navController.popBackStack()
                        }
                    }
                }

                ServiceLoginScreen(
                    source = source,
                    authState = authState,
                    dynamicBackgroundEnabled = themeState.dynamicBackgroundEnabled,
                    onBack = goBack,
                    onServerUrlChange = { authViewModel.updateServerUrl(it) },
                    onUsernameChange = { authViewModel.updateUsername(it) },
                    onPasswordChange = { authViewModel.updatePassword(it) },
                    onLogin = {
                        epochAtOpen = authState.loginEpoch
                        loginAttempted = true
                        authViewModel.login()
                    },
                    onLoginWithToken = { token ->
                        epochAtOpen = authState.loginEpoch
                        loginAttempted = true
                        authViewModel.loginWithToken(token)
                    },
                    onStartOidcLogin = {
                        epochAtOpen = authState.loginEpoch
                        loginAttempted = true
                        authViewModel.startOidcLogin()
                    },
                    onStartPlexOAuth = {
                        epochAtOpen = authState.loginEpoch
                        loginAttempted = true
                        authViewModel.startPlexOAuth()
                    },
                    onCancelPlexOAuth = { authViewModel.cancelPlexOAuth() },
                    onConsumeBrowserAuthUrl = { authViewModel.consumeBrowserAuthUrl() },
                    onLogout = { authViewModel.logout() },
                    onAddLocalLibrary = { uri, name ->
                        epochAtOpen = authState.loginEpoch
                        loginAttempted = true
                        authViewModel.addLocalLibrary(uri, name)
                    },
                    onUrlSchemeChange = { authViewModel.updateUrlScheme(it) },
                    onAuthModeChange = { authViewModel.updateAuthMode(it) },
                    onCustomHeaderAdd = { key, value -> authViewModel.updateCustomHeader(key, value) },
                    onCustomHeaderRemove = { key -> authViewModel.removeCustomHeader(key) },
                    onServiceClientIdChange = { authViewModel.updateServiceClientId(it) },
                    onServiceClientSecretChange = { authViewModel.updateServiceClientSecret(it) },
                    onMtlsEnabledChange = { authViewModel.updateMtlsEnabled(it) },
                    onMtlsCertSelected = { bytes -> authViewModel.stageMtlsCert(bytes) },
                    onMtlsCertPasswordChange = { authViewModel.updateMtlsCertPassword(it) },
                    onMtlsCertClear = { authViewModel.clearStagedMtlsCert() },
                    onKomgaOauthProviderChange = { authViewModel.setKomgaOauthProvider(it) },
                    onStartQuickConnect = { authViewModel.startJellyfinQuickConnect() },
                    onCancelQuickConnect = { authViewModel.cancelJellyfinQuickConnect() },
                    onCloudRootToggle = { path, selected -> authViewModel.updateCloudRootSelection(path, selected) },
                    onSaveCloudRoots = { paths -> authViewModel.saveCloudRootSelection(paths) },
                    onCompleteKomgaOauth = { cookie ->
                        epochAtOpen = authState.loginEpoch
                        loginAttempted = true
                        authViewModel.completeKomgaOauth(cookie)
                    },
                    onCancelKomgaOauth = { authViewModel.cancelKomgaOauth() },
                    onStageLoginCookie = { cookie -> authViewModel.stagePendingLoginCookie(cookie) },
                    onStageLoginHeaders = { headers -> authViewModel.stagePendingLoginHeaders(headers) },
                )
            }

            composable(Routes.LIBRARY_DISPLAY) {
                LibraryDisplaySettingsScreen(
                    onBack = goBack,
                )
            }

            composable(Routes.APPEARANCE) {
                AppearanceScreen(
                    currentTheme = themeState.appTheme,
                    currentColor = themeState.themeColor,
                    dynamicBackgroundEnabled = themeState.dynamicBackgroundEnabled,
                    onThemeChange = { themeViewModel.setThemeMode(it) },
                    onColorChange = { themeViewModel.setThemeColor(it) },
                    onDynamicBackgroundChange = { themeViewModel.setDynamicBackgroundEnabled(it) },
                    onNavigateToEinkHub = { navController.navigate(Routes.EINK_HUB) },
                    onNavigateToCustomFonts = { navController.navigate(Routes.CUSTOM_FONTS) },
                    onBack = goBack,
                )
            }

            composable(Routes.CUSTOM_FONTS) {
                CustomFontsScreen(onBack = goBack)
            }

            composable(Routes.DOWNLOADS) {
                DownloadsHubScreen(
                    state = downloadsHubState,
                    onRefresh = { downloadsHubViewModel.refresh() },
                    onBack = goBack,
                    onRemoveItem = { bookId -> downloadsHubViewModel.removeItem(bookId) },
                    onCancelDownload = { bookId -> downloadsHubViewModel.cancelActiveDownload(bookId) },
                    autoDeleteFinishedBooks = downloadsHubState.autoDeleteFinishedBooks,
                    autoDeleteFailedDownloads = downloadsHubState.autoDeleteFailedDownloads,
                    seriesPreDownloadCount = downloadsHubState.seriesPreDownloadCount,
                    keepNextOfflineEnabled = downloadsHubState.keepNextOfflineEnabled,
                    keepNextOfflineCount = downloadsHubState.keepNextOfflineCount,
                    onAutoDeleteFinishedBooksChange = { downloadsHubViewModel.setAutoDeleteFinishedBooks(it) },
                    onAutoDeleteFailedDownloadsChange = { downloadsHubViewModel.setAutoDeleteFailedDownloads(it) },
                    onSeriesPreDownloadCountChange = { downloadsHubViewModel.setSeriesPreDownloadCount(it) },
                    onKeepNextOfflineEnabledChange = { downloadsHubViewModel.setKeepNextOfflineEnabled(it) },
                    onKeepNextOfflineCountChange = { downloadsHubViewModel.setKeepNextOfflineCount(it) },
                    onDownloadOnCellularChange = { downloadsHubViewModel.setDownloadOnCellular(it) },
                )
            }

            composable(Routes.STORAGE) {
                StorageHubScreen(
                    state = storageHubState,
                    onRefresh = { storageHubViewModel.refresh() },
                    onClearCache = { storageHubViewModel.clearCache() },
                    onClearDownloads = { storageHubViewModel.clearDownloads() },
                    onBack = goBack,
                )
            }

            composable(Routes.SYNC_CLOUD) {
                val syncCenterViewModel: com.enve.app.viewmodel.SyncCenterViewModel = hiltViewModel()
                val syncCenterState by syncCenterViewModel.state.collectAsState()
                SyncCenterScreen(
                    state = syncCenterState,
                    onBack = goBack,
                    onAutoSyncChange = { syncCenterViewModel.setAutoSyncOnLaunch(it) },
                    onSyncOnCellularChange = { syncCenterViewModel.setSyncOnCellular(it) },
                    onSyncNow = { syncCenterViewModel.syncNow() },
                    onKoreaderUsernameChange = { syncCenterViewModel.setKoreaderUsername(it) },
                    onKoreaderPasswordChange = { syncCenterViewModel.setKoreaderPassword(it) },
                    onSaveKoreaderCredentials = { syncCenterViewModel.saveKoreaderCredentials() },
                    onTestKoreaderAuth = { syncCenterViewModel.testKoreaderAuth() },
                    onClearKoreaderCredentials = { syncCenterViewModel.clearKoreaderCredentials() },
                )
            }

            composable(Routes.KOREADER_HUB) {
                KOReaderHubScreen(onBack = goBack)
            }

            composable(Routes.OBSIDIAN_SYNC) {
                ObsidianSyncScreen(onBack = goBack)
            }

            composable(Routes.VOCABULARY_HUB) {
                com.enve.app.ui.screens.VocabularyHubScreen(
                    onBack = goBack,
                    onStudy = { navController.navigate(Routes.VOCABULARY_STUDY) },
                    onSettings = { navController.navigate(Routes.VOCABULARY_SETTINGS) },
                )
            }
            composable(Routes.VOCABULARY_STUDY) {
                com.enve.app.ui.screens.VocabStudyScreen(onBack = goBack)
            }
            composable(Routes.VOCABULARY_SETTINGS) {
                com.enve.app.ui.screens.VocabSettingsScreen(onBack = goBack)
            }
            composable(Routes.DICTIONARIES) {
                com.enve.app.ui.screens.DictionariesSettingsScreen(onBack = goBack)
            }

            composable(Routes.HIDDEN_BOOKS) {
                HiddenBooksScreen(
                    onBack = goBack,
                    dynamicBackgroundEnabled = themeState.dynamicBackgroundEnabled,
                )
            }

            composable(Routes.ACCESSIBILITY) {
                AccessibilityScreen(
                    currentTheme = themeState.appTheme,
                    dynamicBackgroundEnabled = themeState.dynamicBackgroundEnabled,
                    onHighContrastChange = { enabled ->
                        if (enabled) {
                            themeViewModel.setThemeMode(com.enve.app.ui.theme.AppTheme.EINK)
                        } else if (themeState.appTheme == com.enve.app.ui.theme.AppTheme.EINK) {
                            themeViewModel.setThemeMode(com.enve.app.ui.theme.AppTheme.DARK)
                        }
                    },
                    onReduceMotionChange = { enabled ->
                        themeViewModel.setDynamicBackgroundEnabled(!enabled)
                    },
                    onBack = goBack,
                )
            }

            composable(Routes.EINK_HUB) {
                val einkRefreshStrength by themeViewModel.einkRefreshStrength.collectAsState()
                val einkBoldText by themeViewModel.einkBoldText.collectAsState()
                val einkFullRefreshEveryN by themeViewModel.einkFullRefreshEveryN.collectAsState()
                EinkHubScreen(
                    displayMode = themeState.einkDisplayMode,
                    deviceProfile = themeState.einkDeviceProfile,
                    refreshStrength = einkRefreshStrength,
                    boldText = einkBoldText,
                    fullRefreshEveryN = einkFullRefreshEveryN,
                    dynamicBackgroundEnabled = themeState.dynamicBackgroundEnabled,
                    onDisplayModeChange = { themeViewModel.setEinkDisplayMode(it) },
                    onRefreshStrengthChange = { themeViewModel.setEinkRefreshStrength(it) },
                    onBoldTextChange = { themeViewModel.setEinkBoldText(it) },
                    onFullRefreshEveryNChange = { themeViewModel.setEinkFullRefreshEveryN(it) },
                    onManualRefresh = { epdRefreshManager?.requestFullRefresh(rootView) },
                    onBack = goBack,
                )
            }

            composable(Routes.PLAYBACK) {
                PlaybackSettingsScreen(
                    onBack = goBack,
                    dynamicBackgroundEnabled = themeState.dynamicBackgroundEnabled,
                    playbackSpeed = playerState.playbackSpeed,
                    skipBackwardSecs = playerState.skipBackwardSeconds,
                    skipForwardSecs = playerState.skipForwardSeconds,
                    voiceBoost = playerState.voiceBoostEnabled,
                    keepScreenOn = playerState.keepScreenOn,
                    continuousPlayback = playerState.continuousPlayback,
                    autoPlayNextInSeries = playerState.autoPlayNextInSeries,
                    volumeBoost = playerState.volumeBoostEnabled,
                    sleepTimerActive = playerState.sleepTimerMinutes != null,
                    sleepMinutes = playerState.sleepTimerMinutes ?: 30,
                    sleepTimerFadeEnabled = playerState.sleepTimerFadeEnabled,
                    onPlaybackSpeedChange = { playerViewModel.setPlaybackSpeed(it) },
                    onSkipBackwardChange = { playerViewModel.setSkipBackwardSeconds(it) },
                    onSkipForwardChange = { playerViewModel.setSkipForwardSeconds(it) },
                    onVoiceBoostChange = { playerViewModel.setVoiceBoostEnabled(it) },
                    onKeepScreenOnChange = { playerViewModel.setKeepScreenOn(it) },
                    onContinuousPlaybackChange = { playerViewModel.setContinuousPlayback(it) },
                    onAutoPlayNextInSeriesChange = { playerViewModel.setAutoPlayNextInSeries(it) },
                    onVolumeBoostChange = { playerViewModel.setVolumeBoostEnabled(it) },
                    onSleepTimerChange = { playerViewModel.setSleepTimer(it) },
                    onSleepTimerFadeChange = { playerViewModel.setSleepTimerFadeEnabled(it) },
                    onNavigateToAudioEffects = {
                        navController.navigate(Routes.AUDIO_EFFECTS)
                    },
                )
            }

            composable(Routes.ABOUT) {
                AboutScreen(
                    dynamicBackgroundEnabled = themeState.dynamicBackgroundEnabled,
                    onOpenTipJar = openTipJar,
                    onReportIssue = reportIssue,
                    onRateApp = rateApp,
                    onOpenWebsite = openWebsite,
                    onOpenPrivacyPolicy = openPrivacyPolicy,
                    onBack = goBack,
                )
            }

            composable(Routes.CRASH_LOGS) {
                CrashLogsScreen(onBack = goBack)
            }

            composable(Routes.TIP_JAR) {
                val tipJarViewModel: TipJarViewModel = hiltViewModel()
                val tipJarState by tipJarViewModel.state.collectAsState()
                TipJarScreen(
                    state = tipJarState,
                    dynamicBackgroundEnabled = themeState.dynamicBackgroundEnabled,
                    onBack = goBack,
                    onRetry = tipJarViewModel::retry,
                    onDismissNotice = tipJarViewModel::dismissNotice,
                    onTip = { productId ->
                        tipJarViewModel.purchase(context as android.app.Activity, productId)
                    },
                )
            }

            composable(Routes.AUDIO_EFFECTS) {
                AudioEffectsScreen(
                    viewModel = playerViewModel,
                    dynamicBackgroundEnabled = themeState.dynamicBackgroundEnabled,
                    onBack = goBack,
                )
            }

        }

        if (authState.isInitialized && authState.showDiscordAnnouncement) {
            val discordUrl = "https://discord.gg/nXtASwRkQy"
            AlertDialog(
                onDismissRequest = { authViewModel.dismissDiscordAnnouncement() },
                title = { Text("Enve now has a Discord 🎉") },
                text = {
                    Text(
                        "I've finally set up a Discord server, this is the best place to report issues, share feedback, and stay up to date on what's happening with the app. Hope to see you there!"
                    )
                },
                confirmButton = {
                    TextButton(
                        onClick = {
                            authViewModel.dismissDiscordAnnouncement()
                            runCatching {
                                context.startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse(discordUrl))
                                )
                            }
                        }
                    ) {
                        Text("Join Discord")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { authViewModel.dismissDiscordAnnouncement() }) {
                        Text("Maybe later")
                    }
                },
            )
        }
    }
    }
}
