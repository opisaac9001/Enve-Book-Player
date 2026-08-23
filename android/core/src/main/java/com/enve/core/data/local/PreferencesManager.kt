// AGENT-LOCKED
package com.enve.core.data.local

import com.enve.core.auth.CredentialVault
import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.*
import org.json.JSONObject
import com.enve.core.data.model.BookSource
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PreferencesManager @Inject constructor(
    @ApplicationContext private val context: Context,
    private val vault: CredentialVault,
) {
    private val dataStore get() = context.enveDataStore
    private val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main.immediate)
    private val pendingPublisherStyles = PendingPublisherStyles()

    @Volatile private var cachedServerUrl: String? = null
    @Volatile private var cachedUsername: String? = null
    @Volatile private var cachedActiveSource: BookSource = BookSource.GRIMMORY
    @Volatile private var cachedActiveConnectionId: String? = null
    @Volatile private var cachedPlexClientIdentifier: String? = null

    init {
        scope.launch {
            val initial = dataStore.data.first()
            cachedServerUrl = initial[Keys.SERVER_URL]
            cachedUsername = initial[Keys.USERNAME]
            cachedActiveSource = runCatching {
                BookSource.valueOf(initial[Keys.ACTIVE_BOOK_SOURCE] ?: BookSource.GRIMMORY.name)
            }.getOrDefault(BookSource.GRIMMORY)
            cachedActiveConnectionId = initial[Keys.ACTIVE_CONNECTION_ID]
            cachedPlexClientIdentifier = initial[Keys.PLEX_CLIENT_IDENTIFIER]
        }
    }

    private object Keys {
        val HAS_COMPLETED_ONBOARDING = booleanPreferencesKey("enve.hasCompletedOnboarding")
        val SERVER_URL = stringPreferencesKey("enve.serverUrl")
        val USERNAME = stringPreferencesKey("enve.username")
        val IS_CONNECTED = booleanPreferencesKey("enve.isConnected")
        val ACTIVE_BOOK_SOURCE = stringPreferencesKey("enve.activeBookSource")

        val ACTIVE_CONNECTION_ID = stringPreferencesKey("enve.activeConnectionId")

        val PENDING_LOGIN_COOKIE = stringPreferencesKey("enve.pendingLoginCookie")
        val PENDING_LOGIN_HEADERS = stringPreferencesKey("enve.pendingLoginHeaders")
        val MIGRATION_COMPLETED = booleanPreferencesKey("enve.migrationCompleted")
        val THEME_MODE = stringPreferencesKey("enve.themeMode")
        val THEME_COLOR_HEX = stringPreferencesKey("enve.themeColorHex")
        val MEDIA_TYPE = stringPreferencesKey("enve.mediaType")
        val WEEKLY_GOAL_HOURS = floatPreferencesKey("enve.stats.weeklyGoalHours")
        val LIBRARY_LAYOUT = stringPreferencesKey("enve.libraryLayout")

        val LIBRARY_SORT_OPTION = stringPreferencesKey("enve.library.sortOption")
        val LIBRARY_SORT_SECONDARY = stringPreferencesKey("enve.library.sortSecondary")
        val LIBRARY_SORT_DIRECTION = stringPreferencesKey("enve.library.sortDirection")
        val LIBRARY_FILTER_READ_STATUS = stringPreferencesKey("enve.library.filterReadStatus")
        val LIBRARY_FILTER_DOWNLOADED_ONLY = booleanPreferencesKey("enve.library.filterDownloadedOnly")

        val AUTO_DELETE_FINISHED_BOOKS = booleanPreferencesKey("enve.downloads.autoDeleteFinished")
        val AUTO_DELETE_FAILED_DOWNLOADS = booleanPreferencesKey("enve.downloads.autoDeleteFailed")
        val SERIES_PRE_DOWNLOAD_COUNT = androidx.datastore.preferences.core.intPreferencesKey("enve.downloads.seriesPreDownloadCount")
        val SERIES_POLICY_JSON = stringPreferencesKey("enve.downloads.seriesPolicyJson")
        val LIBRARY_FILTER_IN_PROGRESS_ONLY = booleanPreferencesKey("enve.library.filterInProgressOnly")
        val LIBRARY_FILTER_COMPLETED_ONLY = booleanPreferencesKey("enve.library.filterCompletedOnly")
        val LIBRARY_FILTER_NOT_STARTED_ONLY = booleanPreferencesKey("enve.library.filterNotStartedOnly")
        val LIBRARY_SELECTED_ID = stringPreferencesKey("enve.library.selectedId")
        val LIBRARY_HIDDEN_BOOK_IDS = stringPreferencesKey("enve.library.hiddenBookIds")
        val BROWSE_SELECTED_TAB = stringPreferencesKey("enve.browse.selectedTab")
        val PLAYBACK_SPEED = floatPreferencesKey("enve.playbackSpeed")
        val SKIP_FORWARD_SECONDS = intPreferencesKey("enve.skipForward")
        val SKIP_BACKWARD_SECONDS = intPreferencesKey("enve.skipBackward")
        val VOICE_BOOST_ENABLED = booleanPreferencesKey("enve.voiceBoost")
        val KEEP_SCREEN_ON = booleanPreferencesKey("enve.keepScreenOn")
        val CONTINUOUS_PLAYBACK = booleanPreferencesKey("enve.continuousPlayback")
        val AUTO_PLAY_NEXT_IN_SERIES = booleanPreferencesKey("enve.autoPlayNextInSeries")
        val VOLUME_BOOST_ENABLED = booleanPreferencesKey("enve.volumeBoost")
        val DYNAMIC_BACKGROUND_ENABLED = booleanPreferencesKey("enve.dynamicBackground")
        val PLAYER_BACKGROUND_STYLE = stringPreferencesKey("enve.playerBackgroundStyle")
        val SHOW_SPLASH_LOGO = booleanPreferencesKey("enve.showSplashLogo")
        val EINK_DISPLAY_MODE = stringPreferencesKey("enve.eink.displayMode")
        val EINK_REFRESH_STRENGTH = intPreferencesKey("enve.eink.refreshStrength")
        val EINK_BOLD_TEXT = booleanPreferencesKey("enve.eink.boldText")
        val EINK_FULL_REFRESH_EVERY_N = intPreferencesKey("enve.eink.fullRefreshEveryN")
        val LAST_SYNC_TIME = longPreferencesKey("enve.lastSyncTime")
        val AUTO_SYNC_ON_LAUNCH = booleanPreferencesKey("enve.autoSyncOnLaunch")
        val SYNC_ON_CELLULAR = booleanPreferencesKey("enve.syncOnCellular")
        val DOWNLOAD_ON_CELLULAR = booleanPreferencesKey("enve.downloads.allowCellular")
        val VOCAB_AUTO_LOG = booleanPreferencesKey("enve.vocab.autoLogLookups")
        val VOCAB_DAILY_NEW_LIMIT = androidx.datastore.preferences.core.intPreferencesKey("enve.vocab.dailyNewLimit")
        val VOCAB_SHOW_SENTENCE_FIRST = booleanPreferencesKey("enve.vocab.showSentenceFirst")
        val VOCAB_SHUFFLE_QUEUE = booleanPreferencesKey("enve.vocab.shuffleQueue")
        val KOSYNC_HUB_SERVER_URL = stringPreferencesKey("enve.kosyncHub.serverUrl")
        val KOSYNC_HUB_USERNAME = stringPreferencesKey("enve.kosyncHub.username")
        val KOSYNC_HUB_AUTO_SYNC = booleanPreferencesKey("enve.kosyncHub.autoSync")
        val KOSYNC_HUB_LAST_SYNC_TIME = longPreferencesKey("enve.kosyncHub.lastSyncTime")
        val OBSIDIAN_TREE_URI = stringPreferencesKey("enve.obsidian.treeUri")

        val EQ_ENABLED = booleanPreferencesKey("enve.eq.enabled")
        val EQ_PRESET = stringPreferencesKey("enve.eq.preset")
        val EQ_BAND_LEVELS = stringPreferencesKey("enve.eq.bandLevels")
        val VOLUME_BOOST_GAIN_MB = intPreferencesKey("enve.volumeBoostGainMb")
        val BASS_BOOST_ENABLED = booleanPreferencesKey("enve.bassBoostEnabled")
        val BASS_BOOST_STRENGTH = intPreferencesKey("enve.bassBoostStrength")
        val SLEEP_TIMER_FADE = booleanPreferencesKey("enve.sleepTimerFade")
        val PLEX_CLIENT_IDENTIFIER = stringPreferencesKey("enve.plexClientIdentifier")

        val PLEX_OWNER_TOKEN = stringPreferencesKey("enve.plexOwnerToken")
        val PLEX_CURRENT_USER_ID = stringPreferencesKey("enve.plexCurrentUserId")
        val LAST_ANNOUNCEMENT_SEEN = intPreferencesKey("enve.lastAnnouncementSeen")
        val EXCLUDED_LIBRARY_IDS = stringPreferencesKey("enve.library.excludedLibraryIds")
        val LIBRARY_BOOK_CARD_STYLE = stringPreferencesKey("enve.library.bookCardStyle")
        val TITLE_DISPLAY_MODE = stringPreferencesKey("enve.library.titleDisplayMode")
        val SUBTITLE_HANDLING = stringPreferencesKey("enve.library.subtitleHandling")
        val MERGE_AGGRESSIVENESS = stringPreferencesKey("enve.library.mergeAggressiveness")
        val SHOW_ADVANCED_LIBRARY_SETTINGS = booleanPreferencesKey("enve.library.showAdvancedSettings")
        val AUTHOR_GROUPING_THRESHOLD = floatPreferencesKey("enve.library.authorGroupingThreshold")
    }

    val accessToken: Flow<String?> = flow { emit(vault.get(CredentialVault.KEY_ACCESS_TOKEN)) }
    val refreshToken: Flow<String?> = flow { emit(vault.get(CredentialVault.KEY_REFRESH_TOKEN)) }
    val serverUrl: Flow<String?> = dataStore.data.map { it[Keys.SERVER_URL] }
    val username: Flow<String?> = dataStore.data.map { it[Keys.USERNAME] }
    val isConnected: Flow<Boolean> = dataStore.data.map { it[Keys.IS_CONNECTED] ?: false }
    val activeBookSource: Flow<BookSource> = dataStore.data.map {
        runCatching { BookSource.valueOf(it[Keys.ACTIVE_BOOK_SOURCE] ?: BookSource.GRIMMORY.name) }
            .getOrDefault(BookSource.GRIMMORY)
    }
    val activeConnectionId: Flow<String?> = dataStore.data.map {
        it[Keys.ACTIVE_CONNECTION_ID]?.takeIf { id -> id.isNotBlank() }
    }
    val migrationCompleted: Flow<Boolean> = dataStore.data.map {
        it[Keys.MIGRATION_COMPLETED] ?: false
    }

    val lastAnnouncementSeen: Flow<Int> = dataStore.data.map {
        it[Keys.LAST_ANNOUNCEMENT_SEEN] ?: 0
    }

    suspend fun markAnnouncementSeen(versionCode: Int) {
        dataStore.edit { it[Keys.LAST_ANNOUNCEMENT_SEEN] = versionCode }
    }

    suspend fun saveAuth(accessToken: String, refreshToken: String?) {
        vault.put(CredentialVault.KEY_ACCESS_TOKEN, accessToken)
        if (refreshToken != null) vault.put(CredentialVault.KEY_REFRESH_TOKEN, refreshToken)
        dataStore.edit { it[Keys.IS_CONNECTED] = true }
    }

    suspend fun saveServerInfo(url: String, username: String) {
        cachedServerUrl = url
        cachedUsername = username
        dataStore.edit {
            it[Keys.SERVER_URL] = url
            it[Keys.USERNAME] = username
        }
    }

    fun getAccessTokenSync(): String? = vault.get(CredentialVault.KEY_ACCESS_TOKEN)
    fun getRefreshTokenSync(): String? = vault.get(CredentialVault.KEY_REFRESH_TOKEN)

    fun getUsernameSync(): String? = cachedUsername ?: runBlocking { username.first() }

    fun getActiveBookSourceSync(): BookSource = cachedActiveSource

    fun getActiveConnectionIdSync(): String? = cachedActiveConnectionId ?: runBlocking { activeConnectionId.first() }

    fun getServerUrlSync(): String? = cachedServerUrl ?: runBlocking { serverUrl.first() }

    suspend fun getOrCreatePlexClientIdentifier(): String {
        cachedPlexClientIdentifier?.let { return it }
        val existing = dataStore.data.first()[Keys.PLEX_CLIENT_IDENTIFIER]
        if (!existing.isNullOrBlank()) {
            cachedPlexClientIdentifier = existing
            return existing
        }

        val generated = "enve-android-${UUID.randomUUID()}"
        var resolved = generated
        dataStore.edit { prefs ->
            resolved = prefs[Keys.PLEX_CLIENT_IDENTIFIER] ?: generated.also {
                prefs[Keys.PLEX_CLIENT_IDENTIFIER] = it
            }
        }
        cachedPlexClientIdentifier = resolved
        return resolved
    }

    fun getOrCreatePlexClientIdentifierSync(): String =
        cachedPlexClientIdentifier ?: runBlocking { getOrCreatePlexClientIdentifier() }

    suspend fun getPlexOwnerToken(): String? =
        dataStore.data.first()[Keys.PLEX_OWNER_TOKEN]

    suspend fun setPlexOwnerToken(token: String?) {
        dataStore.edit { prefs ->
            if (token.isNullOrBlank()) prefs.remove(Keys.PLEX_OWNER_TOKEN)
            else prefs[Keys.PLEX_OWNER_TOKEN] = token
        }
    }

    suspend fun getPlexCurrentUserId(): String? =
        dataStore.data.first()[Keys.PLEX_CURRENT_USER_ID]

    suspend fun setPlexCurrentUserId(userId: String?) {
        dataStore.edit { prefs ->
            if (userId.isNullOrBlank()) prefs.remove(Keys.PLEX_CURRENT_USER_ID)
            else prefs[Keys.PLEX_CURRENT_USER_ID] = userId
        }
    }

    suspend fun setActiveBookSource(source: BookSource) {
        cachedActiveSource = source
        dataStore.edit { it[Keys.ACTIVE_BOOK_SOURCE] = source.name }
    }

    suspend fun clearAuth() {
        cachedUsername = null
        cachedServerUrl = null
        cachedActiveConnectionId = null
        vault.remove(CredentialVault.KEY_ACCESS_TOKEN)
        vault.remove(CredentialVault.KEY_REFRESH_TOKEN)
        dataStore.edit {
            it[Keys.IS_CONNECTED] = false
            it.remove(Keys.SERVER_URL)
            it.remove(Keys.USERNAME)
            it.remove(Keys.ACTIVE_CONNECTION_ID)
        }
    }

    suspend fun setActiveConnectionId(connectionId: String?) {
        cachedActiveConnectionId = connectionId
        dataStore.edit { it[Keys.ACTIVE_CONNECTION_ID] = connectionId ?: "" }
    }

    @Suppress("UNUSED_PARAMETER")
    fun setCachedConnectionContext(
        source: BookSource,
        serverUrl: String,
        username: String,
        connectionId: String,
        accessToken: String?,
        refreshToken: String? = null,
        password: String? = null,
    ) {
        cachedActiveSource = source
        cachedServerUrl = serverUrl
        cachedUsername = username
        cachedActiveConnectionId = connectionId
    }

    suspend fun clearActiveConnectionId() {
        cachedActiveConnectionId = null
        dataStore.edit { it[Keys.ACTIVE_CONNECTION_ID] = "" }
    }

    @Volatile private var cachedPendingLoginCookie: String? = null
    @Volatile private var pendingLoginCookieLoaded: Boolean = false
    @Volatile private var cachedPendingLoginHeaders: Map<String, String> = emptyMap()
    @Volatile private var pendingLoginHeadersLoaded: Boolean = false

    private fun sanitizePendingHeaders(headers: Map<String, String>): Map<String, String> {
        return headers
            .asSequence()
            .map { (key, value) -> key.trim() to value }
            .filter { (key) -> key.isNotBlank() }
            .associate { it }
    }

    private fun encodePendingHeaders(headers: Map<String, String>): String =
        JSONObject(sanitizePendingHeaders(headers)).toString()

    private fun decodePendingHeaders(raw: String): Map<String, String> {
        if (raw.isBlank()) return emptyMap()
        return runCatching {
            val obj = JSONObject(raw)
            val keys = obj.keys()
            buildMap<String, String> {
                while (keys.hasNext()) {
                    val key = keys.next()
                    val value = obj.optString(key, "")
                    if (key.isNotBlank()) put(key, value)
                }
            }
        }.getOrDefault(emptyMap())
    }

    fun stagePendingLoginCookie(cookie: String?) {
        cachedPendingLoginCookie = cookie?.takeIf { it.isNotBlank() }
        pendingLoginCookieLoaded = true
    }

    suspend fun setPendingLoginCookie(cookie: String?) {
        stagePendingLoginCookie(cookie)
        dataStore.edit {
            if (cookie.isNullOrBlank()) it.remove(Keys.PENDING_LOGIN_COOKIE)
            else it[Keys.PENDING_LOGIN_COOKIE] = cookie
        }
    }

    fun getPendingLoginCookieSync(): String? {
        if (pendingLoginCookieLoaded) return cachedPendingLoginCookie
        val raw = runBlocking { dataStore.data.first()[Keys.PENDING_LOGIN_COOKIE] }
        cachedPendingLoginCookie = raw
        pendingLoginCookieLoaded = true
        return raw
    }

    fun stagePendingLoginHeaders(headers: Map<String, String>) {
        cachedPendingLoginHeaders = sanitizePendingHeaders(headers)
        pendingLoginHeadersLoaded = true
    }

    suspend fun setPendingLoginHeaders(headers: Map<String, String>) {
        stagePendingLoginHeaders(headers)
        val sanitized = sanitizePendingHeaders(headers)
        if (sanitized.isEmpty()) {
            dataStore.edit { it.remove(Keys.PENDING_LOGIN_HEADERS) }
        } else {
            dataStore.edit { it[Keys.PENDING_LOGIN_HEADERS] = encodePendingHeaders(sanitized) }
        }
    }

    fun getPendingLoginHeadersSync(): Map<String, String> {
        if (pendingLoginHeadersLoaded) return cachedPendingLoginHeaders
        val raw = runBlocking { dataStore.data.first()[Keys.PENDING_LOGIN_HEADERS] }.orEmpty()
        val parsed = decodePendingHeaders(raw)
        cachedPendingLoginHeaders = parsed
        pendingLoginHeadersLoaded = true
        return parsed
    }

    suspend fun clearPendingLoginContext() {
        stagePendingLoginCookie(null)
        stagePendingLoginHeaders(emptyMap())
        dataStore.edit {
            it.remove(Keys.PENDING_LOGIN_COOKIE)
            it.remove(Keys.PENDING_LOGIN_HEADERS)
        }
    }

    suspend fun setMigrationCompleted() {
        dataStore.edit { it[Keys.MIGRATION_COMPLETED] = true }
    }

    val hasCompletedOnboarding: Flow<Boolean> =
        dataStore.data.map { it[Keys.HAS_COMPLETED_ONBOARDING] ?: false }

    suspend fun setOnboardingCompleted() {
        dataStore.edit { it[Keys.HAS_COMPLETED_ONBOARDING] = true }
    }

    val themeMode: Flow<String> = dataStore.data.map { it[Keys.THEME_MODE] ?: "dark" }
    val themeColorHex: Flow<String> =
        dataStore.data.map { it[Keys.THEME_COLOR_HEX] ?: "#EF4444" }
    val dynamicBackgroundEnabled: Flow<Boolean> =
        dataStore.data.map { it[Keys.DYNAMIC_BACKGROUND_ENABLED] ?: true }
    val playerBackgroundStyle: Flow<String> =
        dataStore.data.map { it[Keys.PLAYER_BACKGROUND_STYLE] ?: "albumArt" }
    val showSplashLogo: Flow<Boolean> =
        dataStore.data.map { it[Keys.SHOW_SPLASH_LOGO] ?: true }
    val einkDisplayMode: Flow<String> =
        dataStore.data.map { it[Keys.EINK_DISPLAY_MODE] ?: "auto" }
    val einkRefreshStrength: Flow<Int> =
        dataStore.data.map { it[Keys.EINK_REFRESH_STRENGTH] ?: 2 }
    val einkBoldText: Flow<Boolean> =
        dataStore.data.map { it[Keys.EINK_BOLD_TEXT] ?: false }
    val einkFullRefreshEveryN: Flow<Int> =
        dataStore.data.map { it[Keys.EINK_FULL_REFRESH_EVERY_N] ?: 6 }

    suspend fun setThemeMode(mode: String) {
        dataStore.edit { it[Keys.THEME_MODE] = mode }
    }

    suspend fun setThemeColorHex(hex: String) {
        dataStore.edit { it[Keys.THEME_COLOR_HEX] = hex }
    }

    suspend fun setEinkDisplayMode(mode: String) {
        dataStore.edit { it[Keys.EINK_DISPLAY_MODE] = mode }
    }

    suspend fun setEinkRefreshStrength(strength: Int) {
        dataStore.edit { it[Keys.EINK_REFRESH_STRENGTH] = strength.coerceIn(0, 3) }
    }

    suspend fun setEinkBoldText(enabled: Boolean) {
        dataStore.edit { it[Keys.EINK_BOLD_TEXT] = enabled }
    }

    suspend fun setEinkFullRefreshEveryN(n: Int) {
        dataStore.edit { it[Keys.EINK_FULL_REFRESH_EVERY_N] = n.coerceIn(1, 30) }
    }

    val mediaType: Flow<String> =
        dataStore.data.map { it[Keys.MEDIA_TYPE] ?: "AUDIOBOOK" }

    suspend fun setMediaType(type: String) {
        dataStore.edit { it[Keys.MEDIA_TYPE] = type }
    }

    val weeklyGoalHours: Flow<Float> =
        dataStore.data.map { it[Keys.WEEKLY_GOAL_HOURS] ?: 0f }

    suspend fun setWeeklyGoalHours(hours: Float) {
        dataStore.edit { it[Keys.WEEKLY_GOAL_HOURS] = hours.coerceIn(0f, 168f) }
    }

    val libraryLayout: Flow<String> =
        dataStore.data.map { it[Keys.LIBRARY_LAYOUT] ?: "TWO_COLUMN" }

    suspend fun setLibraryLayout(layout: String) {
        dataStore.edit { it[Keys.LIBRARY_LAYOUT] = layout }
    }

    val autoDeleteFinishedBooks: Flow<Boolean> =
        dataStore.data.map { it[Keys.AUTO_DELETE_FINISHED_BOOKS] ?: false }

    suspend fun setAutoDeleteFinishedBooks(value: Boolean) {
        dataStore.edit { it[Keys.AUTO_DELETE_FINISHED_BOOKS] = value }
    }

    val autoDeleteFailedDownloads: Flow<Boolean> =
        dataStore.data.map { it[Keys.AUTO_DELETE_FAILED_DOWNLOADS] ?: true }

    suspend fun setAutoDeleteFailedDownloads(value: Boolean) {
        dataStore.edit { it[Keys.AUTO_DELETE_FAILED_DOWNLOADS] = value }
    }

    val seriesPreDownloadCount: Flow<Int> =
        dataStore.data.map { it[Keys.SERIES_PRE_DOWNLOAD_COUNT] ?: 5 }

    suspend fun setSeriesPreDownloadCount(value: Int) {
        dataStore.edit { it[Keys.SERIES_PRE_DOWNLOAD_COUNT] = value.coerceIn(1, 25) }
    }

    val seriesPolicyJson: Flow<String> =
        dataStore.data.map { it[Keys.SERIES_POLICY_JSON].orEmpty() }

    suspend fun setSeriesPolicyJson(json: String) {
        dataStore.edit { it[Keys.SERIES_POLICY_JSON] = json }
    }

    val librarySortOption: Flow<String> =
        dataStore.data.map { it[Keys.LIBRARY_SORT_OPTION] ?: "DATE_ADDED" }

    suspend fun setLibrarySortOption(option: String) {
        dataStore.edit { it[Keys.LIBRARY_SORT_OPTION] = option }
    }

    val librarySortSecondary: Flow<String> =
        dataStore.data.map { it[Keys.LIBRARY_SORT_SECONDARY] ?: "" }

    suspend fun setLibrarySortSecondary(option: String?) {
        dataStore.edit {
            if (option.isNullOrBlank()) it.remove(Keys.LIBRARY_SORT_SECONDARY)
            else it[Keys.LIBRARY_SORT_SECONDARY] = option
        }
    }

    val librarySortDirection: Flow<String> =
        dataStore.data.map { it[Keys.LIBRARY_SORT_DIRECTION] ?: "DESCENDING" }

    suspend fun setLibrarySortDirection(direction: String) {
        dataStore.edit { it[Keys.LIBRARY_SORT_DIRECTION] = direction }
    }

    val libraryFilterReadStatus: Flow<String> =
        dataStore.data.map { it[Keys.LIBRARY_FILTER_READ_STATUS] ?: "" }

    suspend fun setLibraryFilterReadStatus(status: String?) {
        dataStore.edit {
            if (status.isNullOrBlank()) it.remove(Keys.LIBRARY_FILTER_READ_STATUS)
            else it[Keys.LIBRARY_FILTER_READ_STATUS] = status
        }
    }

    val libraryFilterDownloadedOnly: Flow<Boolean> =
        dataStore.data.map { it[Keys.LIBRARY_FILTER_DOWNLOADED_ONLY] ?: false }

    suspend fun setLibraryFilterDownloadedOnly(value: Boolean) {
        dataStore.edit { it[Keys.LIBRARY_FILTER_DOWNLOADED_ONLY] = value }
    }

    val libraryFilterInProgressOnly: Flow<Boolean> =
        dataStore.data.map { it[Keys.LIBRARY_FILTER_IN_PROGRESS_ONLY] ?: false }

    suspend fun setLibraryFilterInProgressOnly(value: Boolean) {
        dataStore.edit { it[Keys.LIBRARY_FILTER_IN_PROGRESS_ONLY] = value }
    }

    val libraryFilterCompletedOnly: Flow<Boolean> =
        dataStore.data.map { it[Keys.LIBRARY_FILTER_COMPLETED_ONLY] ?: false }

    suspend fun setLibraryFilterCompletedOnly(value: Boolean) {
        dataStore.edit { it[Keys.LIBRARY_FILTER_COMPLETED_ONLY] = value }
    }

    val libraryFilterNotStartedOnly: Flow<Boolean> =
        dataStore.data.map { it[Keys.LIBRARY_FILTER_NOT_STARTED_ONLY] ?: false }

    suspend fun setLibraryFilterNotStartedOnly(value: Boolean) {
        dataStore.edit { it[Keys.LIBRARY_FILTER_NOT_STARTED_ONLY] = value }
    }

    val librarySelectedId: Flow<String?> =
        dataStore.data.map { it[Keys.LIBRARY_SELECTED_ID]?.takeIf { id -> id.isNotBlank() } }

    suspend fun setLibrarySelectedId(id: String?) {
        dataStore.edit {
            if (id.isNullOrBlank()) it.remove(Keys.LIBRARY_SELECTED_ID)
            else it[Keys.LIBRARY_SELECTED_ID] = id
        }
    }

    val libraryHiddenBookIds: Flow<Set<String>> =
        dataStore.data.map { prefs ->
            prefs[Keys.LIBRARY_HIDDEN_BOOK_IDS]
                ?.split('\n')
                ?.filter { it.isNotBlank() }
                ?.toSet()
                .orEmpty()
        }

    suspend fun setLibraryHiddenBookIds(ids: Set<String>) {
        dataStore.edit {
            if (ids.isEmpty()) it.remove(Keys.LIBRARY_HIDDEN_BOOK_IDS)
            else it[Keys.LIBRARY_HIDDEN_BOOK_IDS] = ids.joinToString("\n")
        }
    }

    suspend fun updateLibraryHiddenBookIds(transform: (Set<String>) -> Set<String>) {
        dataStore.edit { prefs ->
            val current = prefs[Keys.LIBRARY_HIDDEN_BOOK_IDS]
                ?.split('\n')?.filter { it.isNotBlank() }?.toSet().orEmpty()
            val next = transform(current)
            if (next.isEmpty()) prefs.remove(Keys.LIBRARY_HIDDEN_BOOK_IDS)
            else prefs[Keys.LIBRARY_HIDDEN_BOOK_IDS] = next.joinToString("\n")
        }
    }

    val excludedLibraryIds: Flow<Set<String>> =
        dataStore.data.map { prefs ->
            prefs[Keys.EXCLUDED_LIBRARY_IDS]
                ?.split('\n')
                ?.filter { it.isNotBlank() }
                ?.toSet()
                .orEmpty()
        }

    suspend fun setExcludedLibraryIds(ids: Set<String>) {
        dataStore.edit {
            if (ids.isEmpty()) it.remove(Keys.EXCLUDED_LIBRARY_IDS)
            else it[Keys.EXCLUDED_LIBRARY_IDS] = ids.joinToString("\n")
        }
    }

    val bookCardStyle: Flow<com.enve.core.data.model.BookCardStyle> =
        dataStore.data.map { prefs ->
            runCatching { com.enve.core.data.model.BookCardStyle.valueOf(prefs[Keys.LIBRARY_BOOK_CARD_STYLE] ?: "") }
                .getOrDefault(com.enve.core.data.model.BookCardStyle.STANDARD)
        }

    suspend fun setBookCardStyle(style: com.enve.core.data.model.BookCardStyle) {
        dataStore.edit { it[Keys.LIBRARY_BOOK_CARD_STYLE] = style.name }
    }

    val titleDisplayMode: Flow<com.enve.core.data.model.TitleDisplayMode> =
        dataStore.data.map { prefs ->
            runCatching { com.enve.core.data.model.TitleDisplayMode.valueOf(prefs[Keys.TITLE_DISPLAY_MODE] ?: "") }
                .getOrDefault(com.enve.core.data.model.TitleDisplayMode.PRESERVE)
        }

    suspend fun setTitleDisplayMode(mode: com.enve.core.data.model.TitleDisplayMode) {
        dataStore.edit { it[Keys.TITLE_DISPLAY_MODE] = mode.name }
    }

    val subtitleHandling: Flow<com.enve.core.data.model.SubtitleHandling> =
        dataStore.data.map { prefs ->
            runCatching { com.enve.core.data.model.SubtitleHandling.valueOf(prefs[Keys.SUBTITLE_HANDLING] ?: "") }
                .getOrDefault(com.enve.core.data.model.SubtitleHandling.KEEP)
        }

    suspend fun setSubtitleHandling(handling: com.enve.core.data.model.SubtitleHandling) {
        dataStore.edit { it[Keys.SUBTITLE_HANDLING] = handling.name }
    }

    val mergeAggressiveness: Flow<com.enve.core.data.model.MergeAggressiveness> =
        dataStore.data.map { prefs ->
            runCatching { com.enve.core.data.model.MergeAggressiveness.valueOf(prefs[Keys.MERGE_AGGRESSIVENESS] ?: "") }
                .getOrDefault(com.enve.core.data.model.MergeAggressiveness.NORMAL)
        }

    suspend fun setMergeAggressiveness(aggressiveness: com.enve.core.data.model.MergeAggressiveness) {
        dataStore.edit { it[Keys.MERGE_AGGRESSIVENESS] = aggressiveness.name }
    }

    val showAdvancedLibrarySettings: Flow<Boolean> =
        dataStore.data.map { it[Keys.SHOW_ADVANCED_LIBRARY_SETTINGS] ?: false }

    suspend fun setShowAdvancedLibrarySettings(value: Boolean) {
        dataStore.edit { it[Keys.SHOW_ADVANCED_LIBRARY_SETTINGS] = value }
    }

    val authorGroupingThreshold: Flow<Float> =
        dataStore.data.map { it[Keys.AUTHOR_GROUPING_THRESHOLD] ?: 0.85f }

    suspend fun setAuthorGroupingThreshold(value: Float) {
        dataStore.edit { it[Keys.AUTHOR_GROUPING_THRESHOLD] = value }
    }

    val browseSelectedTab: Flow<String> =
        dataStore.data.map { it[Keys.BROWSE_SELECTED_TAB] ?: "SERIES" }

    suspend fun setBrowseSelectedTab(tab: String) {
        dataStore.edit { it[Keys.BROWSE_SELECTED_TAB] = tab }
    }

    suspend fun clearLibraryFilters() {
        dataStore.edit {
            it[Keys.LIBRARY_SORT_OPTION] = "DATE_ADDED"
            it.remove(Keys.LIBRARY_SORT_SECONDARY)
            it[Keys.LIBRARY_SORT_DIRECTION] = "DESCENDING"
            it.remove(Keys.LIBRARY_FILTER_READ_STATUS)
            it[Keys.LIBRARY_FILTER_DOWNLOADED_ONLY] = false
            it[Keys.LIBRARY_FILTER_IN_PROGRESS_ONLY] = false
            it[Keys.LIBRARY_FILTER_COMPLETED_ONLY] = false
            it[Keys.LIBRARY_FILTER_NOT_STARTED_ONLY] = false
        }
    }

    val playbackSpeed: Flow<Float> =
        dataStore.data.map { it[Keys.PLAYBACK_SPEED] ?: 1.0f }
    val skipForwardSeconds: Flow<Int> =
        dataStore.data.map { it[Keys.SKIP_FORWARD_SECONDS] ?: 30 }
    val skipBackwardSeconds: Flow<Int> =
        dataStore.data.map { it[Keys.SKIP_BACKWARD_SECONDS] ?: 30 }
    val voiceBoostEnabled: Flow<Boolean> =
        dataStore.data.map { it[Keys.VOICE_BOOST_ENABLED] ?: false }
    val keepScreenOn: Flow<Boolean> =
        dataStore.data.map { it[Keys.KEEP_SCREEN_ON] ?: true }
    val continuousPlayback: Flow<Boolean> =
        dataStore.data.map { it[Keys.CONTINUOUS_PLAYBACK] ?: true }
    val autoPlayNextInSeries: Flow<Boolean> =
        dataStore.data.map { it[Keys.AUTO_PLAY_NEXT_IN_SERIES] ?: false }
    val volumeBoostEnabled: Flow<Boolean> =
        dataStore.data.map { it[Keys.VOLUME_BOOST_ENABLED] ?: false }

    suspend fun setPlaybackSpeed(speed: Float) {
        dataStore.edit { it[Keys.PLAYBACK_SPEED] = speed.coerceIn(0.5f, 3.0f) }
    }

    suspend fun setSkipForwardSeconds(seconds: Int) {
        dataStore.edit { it[Keys.SKIP_FORWARD_SECONDS] = seconds }
    }

    suspend fun setSkipBackwardSeconds(seconds: Int) {
        dataStore.edit { it[Keys.SKIP_BACKWARD_SECONDS] = seconds }
    }

    suspend fun setVoiceBoostEnabled(enabled: Boolean) {
        dataStore.edit { it[Keys.VOICE_BOOST_ENABLED] = enabled }
    }

    suspend fun setKeepScreenOn(enabled: Boolean) {
        dataStore.edit { it[Keys.KEEP_SCREEN_ON] = enabled }
    }

    suspend fun setContinuousPlayback(enabled: Boolean) {
        dataStore.edit { it[Keys.CONTINUOUS_PLAYBACK] = enabled }
    }

    suspend fun setAutoPlayNextInSeries(enabled: Boolean) {
        dataStore.edit { it[Keys.AUTO_PLAY_NEXT_IN_SERIES] = enabled }
    }

    suspend fun setVolumeBoostEnabled(enabled: Boolean) {
        dataStore.edit { it[Keys.VOLUME_BOOST_ENABLED] = enabled }
    }

    val eqEnabled: Flow<Boolean> =
        dataStore.data.map { it[Keys.EQ_ENABLED] ?: false }
    val eqPreset: Flow<String> =
        dataStore.data.map { it[Keys.EQ_PRESET] ?: "FLAT" }
    val eqBandLevels: Flow<String> =
        dataStore.data.map { it[Keys.EQ_BAND_LEVELS] ?: "" }
    val volumeBoostGainMb: Flow<Int> =
        dataStore.data.map { it[Keys.VOLUME_BOOST_GAIN_MB] ?: 0 }
    val bassBoostEnabled: Flow<Boolean> =
        dataStore.data.map { it[Keys.BASS_BOOST_ENABLED] ?: false }
    val bassBoostStrength: Flow<Int> =
        dataStore.data.map { it[Keys.BASS_BOOST_STRENGTH] ?: 0 }
    val sleepTimerFade: Flow<Boolean> =
        dataStore.data.map { it[Keys.SLEEP_TIMER_FADE] ?: true }

    suspend fun setEqEnabled(enabled: Boolean) {
        dataStore.edit { it[Keys.EQ_ENABLED] = enabled }
    }

    suspend fun setEqPreset(preset: String) {
        dataStore.edit { it[Keys.EQ_PRESET] = preset }
    }

    suspend fun setEqBandLevels(levels: String) {
        dataStore.edit { it[Keys.EQ_BAND_LEVELS] = levels }
    }

    suspend fun setVolumeBoostGainMb(gainMb: Int) {
        dataStore.edit { it[Keys.VOLUME_BOOST_GAIN_MB] = gainMb }
    }

    suspend fun setBassBoostEnabled(enabled: Boolean) {
        dataStore.edit { it[Keys.BASS_BOOST_ENABLED] = enabled }
    }

    suspend fun setBassBoostStrength(strength: Int) {
        dataStore.edit { it[Keys.BASS_BOOST_STRENGTH] = strength }
    }

    suspend fun setSleepTimerFade(enabled: Boolean) {
        dataStore.edit { it[Keys.SLEEP_TIMER_FADE] = enabled }
    }

    suspend fun setDynamicBackgroundEnabled(enabled: Boolean) {
        dataStore.edit { it[Keys.DYNAMIC_BACKGROUND_ENABLED] = enabled }
    }

    suspend fun setPlayerBackgroundStyle(style: String) {
        dataStore.edit { it[Keys.PLAYER_BACKGROUND_STYLE] = style }
    }

    suspend fun setShowSplashLogo(enabled: Boolean) {
        dataStore.edit { it[Keys.SHOW_SPLASH_LOGO] = enabled }
    }

    fun isShowSplashLogoSync(): Boolean = runBlocking { showSplashLogo.first() }

    val lastSyncTime: Flow<Long> = dataStore.data.map { it[Keys.LAST_SYNC_TIME] ?: 0L }
    val autoSyncOnLaunch: Flow<Boolean> = dataStore.data.map { it[Keys.AUTO_SYNC_ON_LAUNCH] ?: true }
    val syncOnCellular: Flow<Boolean> = dataStore.data.map { it[Keys.SYNC_ON_CELLULAR] ?: false }
    val downloadOnCellular: Flow<Boolean> = dataStore.data.map { it[Keys.DOWNLOAD_ON_CELLULAR] ?: false }

    val vocabAutoLogLookups: Flow<Boolean> = dataStore.data.map { it[Keys.VOCAB_AUTO_LOG] ?: true }
    val vocabDailyNewLimit: Flow<Int> = dataStore.data.map { it[Keys.VOCAB_DAILY_NEW_LIMIT] ?: 10 }
    val vocabShowSentenceFirst: Flow<Boolean> = dataStore.data.map { it[Keys.VOCAB_SHOW_SENTENCE_FIRST] ?: false }
    val vocabShuffleQueue: Flow<Boolean> = dataStore.data.map { it[Keys.VOCAB_SHUFFLE_QUEUE] ?: true }

    suspend fun setVocabAutoLogLookups(enabled: Boolean) {
        dataStore.edit { it[Keys.VOCAB_AUTO_LOG] = enabled }
    }

    suspend fun setVocabDailyNewLimit(limit: Int) {
        dataStore.edit { it[Keys.VOCAB_DAILY_NEW_LIMIT] = limit.coerceIn(0, 100) }
    }

    suspend fun setVocabShowSentenceFirst(enabled: Boolean) {
        dataStore.edit { it[Keys.VOCAB_SHOW_SENTENCE_FIRST] = enabled }
    }

    suspend fun setVocabShuffleQueue(enabled: Boolean) {
        dataStore.edit { it[Keys.VOCAB_SHUFFLE_QUEUE] = enabled }
    }

    suspend fun setLastSyncTime(time: Long) {
        dataStore.edit { it[Keys.LAST_SYNC_TIME] = time }
    }

    suspend fun setAutoSyncOnLaunch(enabled: Boolean) {
        dataStore.edit { it[Keys.AUTO_SYNC_ON_LAUNCH] = enabled }
    }

    suspend fun setSyncOnCellular(enabled: Boolean) {
        dataStore.edit { it[Keys.SYNC_ON_CELLULAR] = enabled }
    }

    suspend fun setDownloadOnCellular(enabled: Boolean) {
        dataStore.edit { it[Keys.DOWNLOAD_ON_CELLULAR] = enabled }
    }

    val kosyncHubServerUrl: Flow<String> = dataStore.data.map { it[Keys.KOSYNC_HUB_SERVER_URL] ?: "" }
    val kosyncHubUsername: Flow<String> = dataStore.data.map { it[Keys.KOSYNC_HUB_USERNAME] ?: "" }
    val kosyncHubAutoSync: Flow<Boolean> = dataStore.data.map { it[Keys.KOSYNC_HUB_AUTO_SYNC] ?: true }
    val kosyncHubLastSyncTime: Flow<Long> = dataStore.data.map { it[Keys.KOSYNC_HUB_LAST_SYNC_TIME] ?: 0L }

    fun getKosyncHubServerUrlSync(): String = runBlocking { kosyncHubServerUrl.first() }
    fun getKosyncHubUsernameSync(): String = runBlocking { kosyncHubUsername.first() }
    fun getKosyncHubAutoSyncSync(): Boolean = runBlocking { kosyncHubAutoSync.first() }

    suspend fun setKosyncHubConfig(serverUrl: String, username: String, autoSync: Boolean) {
        dataStore.edit {
            it[Keys.KOSYNC_HUB_SERVER_URL] = serverUrl
            it[Keys.KOSYNC_HUB_USERNAME] = username
            it[Keys.KOSYNC_HUB_AUTO_SYNC] = autoSync
        }
    }

    suspend fun clearKosyncHubConfig() {
        dataStore.edit {
            it.remove(Keys.KOSYNC_HUB_SERVER_URL)
            it.remove(Keys.KOSYNC_HUB_USERNAME)
            it.remove(Keys.KOSYNC_HUB_AUTO_SYNC)
        }
    }

    suspend fun setKosyncHubLastSyncTime(time: Long) {
        dataStore.edit { it[Keys.KOSYNC_HUB_LAST_SYNC_TIME] = time }
    }

    val obsidianTreeUri: Flow<String?> = dataStore.data.map { prefs ->
        prefs[Keys.OBSIDIAN_TREE_URI]?.takeIf { it.isNotBlank() }
    }

    suspend fun setObsidianTreeUri(uri: String?) {
        dataStore.edit { prefs ->
            if (uri.isNullOrBlank()) prefs.remove(Keys.OBSIDIAN_TREE_URI)
            else prefs[Keys.OBSIDIAN_TREE_URI] = uri
        }
    }

    private object ReaderKeys {
        val THEME        = stringPreferencesKey("reader.theme")
        val FONT_FAMILY  = stringPreferencesKey("reader.fontFamily")
        val CUSTOM_FONT_NAME = stringPreferencesKey("reader.customFontName")
        val FONT_SIZE    = floatPreferencesKey("reader.fontSize")
        val LINE_HEIGHT  = floatPreferencesKey("reader.lineHeight")
        val PAGE_MARGINS = floatPreferencesKey("reader.pageMargins")
        val VERTICAL_PAGE_MARGINS = floatPreferencesKey("reader.verticalPageMargins")
        val WORD_SPACING = floatPreferencesKey("reader.wordSpacing")
        val LETTER_SPACING = floatPreferencesKey("reader.letterSpacing")
        val SCROLL       = booleanPreferencesKey("reader.scroll")
        val PUBLISHER_STYLES = booleanPreferencesKey("reader.publisherStyles")
        val JUSTIFIED    = booleanPreferencesKey("reader.justified")
        val COLUMN_COUNT = stringPreferencesKey("reader.columnCount")
        val FONT_WEIGHT  = floatPreferencesKey("reader.fontWeight")
        val PARAGRAPH_SPACING = floatPreferencesKey("reader.paragraphSpacing")
        val PARAGRAPH_INDENT = floatPreferencesKey("reader.paragraphIndent")
        val VOLUME_BUTTON_NAV = booleanPreferencesKey("reader.volumeButtonNav")
        val AUTO_SCROLL_SPEED = floatPreferencesKey("reader.autoScrollSpeed")
        val TOOLBAR_BUTTONS = stringPreferencesKey("reader.toolbarButtons")
        val TTS_ENABLED = booleanPreferencesKey("reader.ttsEnabled")
        val TTS_SPEED = floatPreferencesKey("reader.ttsSpeed")
        val READ_ALOUD_SPEED = floatPreferencesKey("reader.readAloud.speed")
        val READ_ALOUD_SYNC_OFFSET_MS = intPreferencesKey("reader.readAloud.syncOffsetMs")
        val READ_ALOUD_AUTO_TURN = booleanPreferencesKey("reader.readAloud.autoTurn")
        val READ_ALOUD_HIGHLIGHT = booleanPreferencesKey("reader.readAloud.highlight")
        val READ_ALOUD_HIGHLIGHT_HEX = stringPreferencesKey("reader.readAloud.highlightHex")
        val READ_ALOUD_SKIP_ASIDES = booleanPreferencesKey("reader.readAloud.skipAsides")
        val SCREEN_BRIGHTNESS = floatPreferencesKey("reader.screenBrightness")
        val SHOW_CLOCK = booleanPreferencesKey("reader.showClock")
        val SHOW_BATTERY = booleanPreferencesKey("reader.showBattery")
        val PROGRESS_DISPLAY = stringPreferencesKey("reader.progressDisplay")
        val TAP_ZONE_WIDTH = floatPreferencesKey("reader.tapZoneWidth")
        val EDGE_BRIGHTNESS_SWIPE = booleanPreferencesKey("reader.edgeBrightnessSwipe")
        val BIONIC_READING = booleanPreferencesKey("reader.bionicReading")
        val COMIC_READING_DIRECTION = stringPreferencesKey("reader.comic.readingDirection")
        val COMIC_PROGRESSION_MODE = stringPreferencesKey("reader.comic.progressionMode")
        val COMIC_PAGE_FIT = stringPreferencesKey("reader.comic.pageFit")
        val COMIC_SPREAD_MODE = stringPreferencesKey("reader.comic.spreadMode")
        val COMIC_ZOOM_ENABLED = booleanPreferencesKey("reader.comic.zoomEnabled")
        val COMIC_AUTO_HIDE_CHROME = booleanPreferencesKey("reader.comic.autoHideChrome")
        val COMIC_BACKGROUND_ARGB = intPreferencesKey("reader.comic.backgroundArgb")
        val COMIC_VOLUME_BUTTON_NAV = booleanPreferencesKey("reader.comic.volumeButtonNav")
        val COMIC_BRIGHTNESS = floatPreferencesKey("reader.comic.brightness")
        val COMIC_BACKGROUND_THEME = stringPreferencesKey("reader.comic.backgroundTheme")
        val COMIC_PAGE_LOADING_MODE = stringPreferencesKey("reader.comic.pageLoadingMode")
    }

    val readerTheme: Flow<String>     = dataStore.data.map { it[ReaderKeys.THEME] ?: "DARK" }
    val readerFontFamily: Flow<String> = dataStore.data.map { it[ReaderKeys.FONT_FAMILY] ?: "SERIF" }

    val readerCustomFontName: Flow<String> = dataStore.data.map { it[ReaderKeys.CUSTOM_FONT_NAME] ?: "" }
    val readerFontSize: Flow<Float>   = dataStore.data.map { it[ReaderKeys.FONT_SIZE] ?: 1.0f }
    val readerLineHeight: Flow<Float> = dataStore.data.map { it[ReaderKeys.LINE_HEIGHT] ?: 1.4f }
    val readerPageMargins: Flow<Float> = dataStore.data.map { it[ReaderKeys.PAGE_MARGINS] ?: 0.5f }
    val readerVerticalPageMargins: Flow<Float> = dataStore.data.map { it[ReaderKeys.VERTICAL_PAGE_MARGINS] ?: 0.5f }
    val readerWordSpacing: Flow<Float> = dataStore.data.map { it[ReaderKeys.WORD_SPACING] ?: 0f }
    val readerLetterSpacing: Flow<Float> = dataStore.data.map { it[ReaderKeys.LETTER_SPACING] ?: 0f }
    val readerScroll: Flow<Boolean>   = dataStore.data.map { it[ReaderKeys.SCROLL] ?: false }
    val readerPublisherStyles: Flow<Boolean> = pendingPublisherStyles.overlay(
        dataStore.data.map { it[ReaderKeys.PUBLISHER_STYLES] ?: true },
    )
    val readerJustified: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.JUSTIFIED] ?: true }
    val readerColumnCount: Flow<String> = dataStore.data.map { it[ReaderKeys.COLUMN_COUNT] ?: "AUTO" }
    val readerFontWeight: Flow<Float>  = dataStore.data.map { it[ReaderKeys.FONT_WEIGHT] ?: 1.0f }
    val readerParagraphSpacing: Flow<Float> = dataStore.data.map { it[ReaderKeys.PARAGRAPH_SPACING] ?: 0f }
    val readerParagraphIndent: Flow<Float> = dataStore.data.map {
        (it[ReaderKeys.PARAGRAPH_INDENT] ?: 0f).coerceIn(0f, 3f)
    }
    val readerVolumeButtonNav: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.VOLUME_BUTTON_NAV] ?: true }
    val readerAutoScrollSpeed: Flow<Float> = dataStore.data.map { it[ReaderKeys.AUTO_SCROLL_SPEED] ?: 0f }
    val readerToolbarButtons: Flow<String> = dataStore.data.map { it[ReaderKeys.TOOLBAR_BUTTONS] ?: "" }
    val readerTtsEnabled: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.TTS_ENABLED] ?: false }
    val readerTtsSpeed: Flow<Float> = dataStore.data.map { it[ReaderKeys.TTS_SPEED] ?: 1.0f }
    val readAloudSpeed: Flow<Float> = dataStore.data.map { it[ReaderKeys.READ_ALOUD_SPEED] ?: 1.0f }
    val readAloudSyncOffsetMs: Flow<Int> = dataStore.data.map { it[ReaderKeys.READ_ALOUD_SYNC_OFFSET_MS] ?: 0 }
    val readAloudAutoTurn: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.READ_ALOUD_AUTO_TURN] ?: true }
    val readAloudHighlight: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.READ_ALOUD_HIGHLIGHT] ?: true }
    val readAloudHighlightHex: Flow<String> = dataStore.data.map { it[ReaderKeys.READ_ALOUD_HIGHLIGHT_HEX] ?: "#FFF59D" }
    val readAloudSkipAsides: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.READ_ALOUD_SKIP_ASIDES] ?: true }
    val readerScreenBrightness: Flow<Float> = dataStore.data.map { it[ReaderKeys.SCREEN_BRIGHTNESS] ?: -1f }
    val readerShowClock: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.SHOW_CLOCK] ?: false }
    val readerShowBattery: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.SHOW_BATTERY] ?: false }
    val readerProgressDisplay: Flow<String> = dataStore.data.map { it[ReaderKeys.PROGRESS_DISPLAY] ?: "NONE" }
    val readerTapZoneWidth: Flow<Float> = dataStore.data.map { it[ReaderKeys.TAP_ZONE_WIDTH] ?: 0.20f }
    val readerEdgeBrightnessSwipe: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.EDGE_BRIGHTNESS_SWIPE] ?: true }
    val readerBionicReading: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.BIONIC_READING] ?: false }
    val comicReadingDirection: Flow<String> = dataStore.data.map { it[ReaderKeys.COMIC_READING_DIRECTION] ?: "LEFT_TO_RIGHT" }
    val comicProgressionMode: Flow<String> = dataStore.data.map { it[ReaderKeys.COMIC_PROGRESSION_MODE] ?: "PAGED" }
    val comicPageFit: Flow<String> = dataStore.data.map { it[ReaderKeys.COMIC_PAGE_FIT] ?: "FIT_WIDTH" }
    val comicSpreadMode: Flow<String> = dataStore.data.map { it[ReaderKeys.COMIC_SPREAD_MODE] ?: "AUTO" }
    val comicZoomEnabled: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.COMIC_ZOOM_ENABLED] ?: true }
    val comicAutoHideChrome: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.COMIC_AUTO_HIDE_CHROME] ?: true }
    val comicBackgroundArgb: Flow<Int> = dataStore.data.map { it[ReaderKeys.COMIC_BACKGROUND_ARGB] ?: 0xFF000000.toInt() }
    val comicVolumeButtonNav: Flow<Boolean> = dataStore.data.map { it[ReaderKeys.COMIC_VOLUME_BUTTON_NAV] ?: false }
    val comicBrightness: Flow<Float> = dataStore.data.map { it[ReaderKeys.COMIC_BRIGHTNESS] ?: -1f }
    val comicBackgroundTheme: Flow<String> = dataStore.data.map { it[ReaderKeys.COMIC_BACKGROUND_THEME] ?: "BLACK" }
    val comicPageLoadingMode: Flow<com.enve.core.data.model.ComicPageLoadingMode> = dataStore.data.map { preferences ->
        preferences[ReaderKeys.COMIC_PAGE_LOADING_MODE]
            ?.let { runCatching { com.enve.core.data.model.ComicPageLoadingMode.valueOf(it) }.getOrNull() }
            ?: com.enve.core.data.model.ComicPageLoadingMode.STREAM
    }

    fun saveReaderPublisherStyles(publisherStyles: Boolean) {
        val pendingWrite = pendingPublisherStyles.begin(publisherStyles)
        scope.launch {
            try {
                dataStore.edit { it[ReaderKeys.PUBLISHER_STYLES] = publisherStyles }
            } finally {
                pendingPublisherStyles.complete(pendingWrite)
            }
        }
    }

    suspend fun saveReaderPreferences(
        theme: String? = null,
        fontFamily: String? = null,
        customFontName: String? = null,
        fontSize: Float? = null,
        lineHeight: Float? = null,
        pageMargins: Float? = null,
        verticalPageMargins: Float? = null,
        wordSpacing: Float? = null,
        letterSpacing: Float? = null,
        scroll: Boolean? = null,
        publisherStyles: Boolean? = null,
        justified: Boolean? = null,
        columnCount: String? = null,
        fontWeight: Float? = null,
        paragraphSpacing: Float? = null,
        paragraphIndent: Float? = null,
        volumeButtonNav: Boolean? = null,
        autoScrollSpeed: Float? = null,
        toolbarButtons: String? = null,
        ttsEnabled: Boolean? = null,
        ttsSpeed: Float? = null,
        readAloudSpeed: Float? = null,
        readAloudSyncOffsetMs: Int? = null,
        readAloudAutoTurn: Boolean? = null,
        readAloudHighlight: Boolean? = null,
        readAloudHighlightHex: String? = null,
        readAloudSkipAsides: Boolean? = null,
        screenBrightness: Float? = null,
        showClock: Boolean? = null,
        showBattery: Boolean? = null,
        progressDisplay: String? = null,
        tapZoneWidth: Float? = null,
        edgeBrightnessSwipe: Boolean? = null,
        bionicReading: Boolean? = null,
    ) {
        val pendingWrite = publisherStyles?.let(pendingPublisherStyles::begin)
        try {
            dataStore.edit { p ->
                theme?.let { p[ReaderKeys.THEME] = it }
                fontFamily?.let { p[ReaderKeys.FONT_FAMILY] = it }
                customFontName?.let { p[ReaderKeys.CUSTOM_FONT_NAME] = it }
                fontSize?.let { p[ReaderKeys.FONT_SIZE] = it }
                lineHeight?.let { p[ReaderKeys.LINE_HEIGHT] = it }
                pageMargins?.let { p[ReaderKeys.PAGE_MARGINS] = it }
                verticalPageMargins?.let { p[ReaderKeys.VERTICAL_PAGE_MARGINS] = it }
                wordSpacing?.let { p[ReaderKeys.WORD_SPACING] = it }
                letterSpacing?.let { p[ReaderKeys.LETTER_SPACING] = it }
                scroll?.let { p[ReaderKeys.SCROLL] = it }
                publisherStyles?.let { p[ReaderKeys.PUBLISHER_STYLES] = it }
                justified?.let { p[ReaderKeys.JUSTIFIED] = it }
                columnCount?.let { p[ReaderKeys.COLUMN_COUNT] = it }
                fontWeight?.let { p[ReaderKeys.FONT_WEIGHT] = it }
                paragraphSpacing?.let { p[ReaderKeys.PARAGRAPH_SPACING] = it }
                paragraphIndent?.let { p[ReaderKeys.PARAGRAPH_INDENT] = it.coerceIn(0f, 3f) }
                volumeButtonNav?.let { p[ReaderKeys.VOLUME_BUTTON_NAV] = it }
                autoScrollSpeed?.let { p[ReaderKeys.AUTO_SCROLL_SPEED] = it }
                toolbarButtons?.let { p[ReaderKeys.TOOLBAR_BUTTONS] = it }
                ttsEnabled?.let { p[ReaderKeys.TTS_ENABLED] = it }
                ttsSpeed?.let { p[ReaderKeys.TTS_SPEED] = it }
                readAloudSpeed?.let { p[ReaderKeys.READ_ALOUD_SPEED] = it }
                readAloudSyncOffsetMs?.let { p[ReaderKeys.READ_ALOUD_SYNC_OFFSET_MS] = it }
                readAloudAutoTurn?.let { p[ReaderKeys.READ_ALOUD_AUTO_TURN] = it }
                readAloudHighlight?.let { p[ReaderKeys.READ_ALOUD_HIGHLIGHT] = it }
                readAloudHighlightHex?.let { p[ReaderKeys.READ_ALOUD_HIGHLIGHT_HEX] = it }
                readAloudSkipAsides?.let { p[ReaderKeys.READ_ALOUD_SKIP_ASIDES] = it }
                screenBrightness?.let { p[ReaderKeys.SCREEN_BRIGHTNESS] = it }
                showClock?.let { p[ReaderKeys.SHOW_CLOCK] = it }
                showBattery?.let { p[ReaderKeys.SHOW_BATTERY] = it }
                progressDisplay?.let { p[ReaderKeys.PROGRESS_DISPLAY] = it }
                tapZoneWidth?.let { p[ReaderKeys.TAP_ZONE_WIDTH] = it }
                edgeBrightnessSwipe?.let { p[ReaderKeys.EDGE_BRIGHTNESS_SWIPE] = it }
                bionicReading?.let { p[ReaderKeys.BIONIC_READING] = it }
            }
        } finally {
            pendingWrite?.let(pendingPublisherStyles::complete)
        }
    }

    suspend fun saveComicReaderPreferences(
        readingDirection: String? = null,
        progressionMode: String? = null,
        pageFit: String? = null,
        spreadMode: String? = null,
        zoomEnabled: Boolean? = null,
        autoHideChrome: Boolean? = null,
        backgroundArgb: Int? = null,
        volumeButtonNav: Boolean? = null,
        brightness: Float? = null,
        backgroundTheme: String? = null,
        pageLoadingMode: com.enve.core.data.model.ComicPageLoadingMode? = null,
    ) {
        dataStore.edit { p ->
            readingDirection?.let { p[ReaderKeys.COMIC_READING_DIRECTION] = it }
            progressionMode?.let { p[ReaderKeys.COMIC_PROGRESSION_MODE] = it }
            pageFit?.let { p[ReaderKeys.COMIC_PAGE_FIT] = it }
            spreadMode?.let { p[ReaderKeys.COMIC_SPREAD_MODE] = it }
            zoomEnabled?.let { p[ReaderKeys.COMIC_ZOOM_ENABLED] = it }
            autoHideChrome?.let { p[ReaderKeys.COMIC_AUTO_HIDE_CHROME] = it }
            backgroundArgb?.let { p[ReaderKeys.COMIC_BACKGROUND_ARGB] = it }
            volumeButtonNav?.let { p[ReaderKeys.COMIC_VOLUME_BUTTON_NAV] = it }
            brightness?.let { p[ReaderKeys.COMIC_BRIGHTNESS] = it }
            backgroundTheme?.let { p[ReaderKeys.COMIC_BACKGROUND_THEME] = it }
            pageLoadingMode?.let { p[ReaderKeys.COMIC_PAGE_LOADING_MODE] = it.name }
        }
    }
}
