// AGENT-LOCKED
package com.enve.app.ui.auth

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.auth.MtlsManager
import com.enve.core.data.auth.PasswordLogin
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ConnectionAuthMode
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.UrlScheme
import com.enve.core.data.provider.DetectedServer
import com.enve.core.data.provider.ServerProbe
import com.enve.core.data.provider.ServerProbeOutcome
import com.enve.core.data.remote.NetworkErrorMapper
import com.enve.app.data.repository.AggregatorRepository
import com.enve.audiobookshelf.AudiobookshelfRepository
import com.enve.bookorbit.auth.BookOrbitOidcFlow
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.komga.KomgaRepository
import com.enve.silo.SiloRepository
import com.enve.app.data.repository.LibraryCacheRepository
import com.enve.storyteller.StorytellerRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

data class QuickConnectUiState(
    val isProbing: Boolean = false,
    val error: String? = null,
    val result: DetectedServer? = null,
)

data class AuthState(
    // Login form fields (not synced from preferences)
    val serverUrl: String = "",
    val username: String = "",
    val password: String = "",

    // Currently active connection info (synced from preferences)
    val activeSource: BookSource = BookSource.GRIMMORY,
    val activeServerUrl: String = "",
    val activeUsername: String = "",

    val selectedSource: BookSource = BookSource.GRIMMORY,
    val editingConnectionId: String? = null,
    val browserAuthUrl: String? = null,
    // Cookie name to poll for instead of waiting on a deep-link callback (Komga "SESSION").
    val browserAuthRequiredCookie: String? = null,
    val browserAuthRequiresOriginReturn: Boolean = false,
    val komgaOauthProvider: String = "",
    val pendingKomgaOauth: Boolean = false,
    val isLoading: Boolean = false,
    val isConnected: Boolean = false,
    val hasCompletedOnboarding: Boolean = false,
    val isInitialized: Boolean = false,
    val showDiscordAnnouncement: Boolean = false,
    val error: String? = null,
    // Plex PIN OAuth
    val plexPinId: Long = 0L,
    val plexPinCode: String = "",
    val plexPolling: Boolean = false,
    // Plex Home user picker — populated when the user opens the switcher.
    val plexHomeUsers: List<com.enve.plex.auth.PlexHomeUser> = emptyList(),
    val plexHomeUsersLoading: Boolean = false,
    val plexHomeUsersError: String? = null,
    val plexCurrentUserId: Long? = null,
    // Multi-service
    val allConnections: List<ProviderConnection> = emptyList(),
    val activeConnectionId: String? = null,

    // Advanced connection options
    val urlScheme: UrlScheme = UrlScheme.HTTPS,
    val authMode: ConnectionAuthMode = ConnectionAuthMode.AUTO,
    val customHeaders: Map<String, String> = emptyMap(),
    val serviceClientId: String = "",
    val serviceClientSecret: String = "",
    val mtlsEnabled: Boolean = false,
    val mtlsCertBytes: ByteArray? = null,
    val mtlsCertPassword: String = "",
    val mtlsCertSubject: String? = null,
    val mtlsCertError: String? = null,

    // Quick Connect (Jellyfin)
    val quickConnectCode: String = "",
    val quickConnectPolling: Boolean = false,
    // Incremented on every successful login so the login screen can dismiss
    // regardless of whether the user was already connected via another source.
    // The prefs.isConnected approach breaks for multi-source because it's always true.
    val loginEpoch: Int = 0,
    val importMessage: String? = null,
    val cloudRootCandidates: List<String> = emptyList(),
    val selectedCloudRootPaths: List<String> = emptyList(),
    val pendingCloudRootConnectionId: String? = null,

    // connectionHealth keyed by ProviderConnection.id; missing key = not yet probed.
    val isCheckingHealth: Boolean = false,
    val connectionHealth: Map<String, Boolean> = emptyMap(),
) {
    // Effective headers merge: customHeaders + service tokens
    val effectiveHeaders: Map<String, String>
        get() {
            val merged = customHeaders.toMutableMap()
            if (serviceClientId.isNotBlank()) merged["CF-Access-Client-Id"] = serviceClientId
            if (serviceClientSecret.isNotBlank()) merged["CF-Access-Client-Secret"] = serviceClientSecret
            return merged
        }
}

@HiltViewModel
class AuthViewModel @Inject constructor(
    private val repository: GrimmoryRepository,
    private val storytellerRepository: StorytellerRepository,
    private val prefs: PreferencesManager,
    private val connectionRegistry: ConnectionRegistry,
    private val vault: CredentialVault,
    private val mtlsManager: MtlsManager,
    private val libraryCacheRepository: LibraryCacheRepository,
    private val aggregatorRepository: AggregatorRepository,
    private val absRepository: AudiobookshelfRepository,
    private val komgaRepository: KomgaRepository,
    private val siloRepository: SiloRepository,
    private val jellyfinRepository: com.enve.app.data.repository.JellyfinRepository,
    private val plexPinAuth: com.enve.plex.auth.PlexPinAuthService,
    private val plexPinAuthFlow: com.enve.plex.auth.PlexPinAuthFlow,
    private val jellyfinQuickConnectFlow: com.enve.app.data.jellyfin.JellyfinQuickConnectFlow,
    private val grimmoryOidcFlow: com.enve.app.data.grimmory.auth.GrimmoryOidcFlow,
    private val absOidcFlow: com.enve.audiobookshelf.auth.AbsOidcFlow,
    private val komgaOAuthFlow: com.enve.komga.auth.KomgaOAuthFlow,
    private val bookOrbitOidcFlow: BookOrbitOidcFlow,
    private val passwordLogins: Map<BookSource, @JvmSuppressWildcards PasswordLogin>,
) : ViewModel() {

    private val _state = MutableStateFlow(AuthState())
    val state: StateFlow<AuthState> = _state.asStateFlow()

    private var plexPollJob: Job? = null

    companion object {
        const val PLEX_APP_NAME = "Enve"
    }

    init {
        viewModelScope.launch {
            // Run migration before anything else touches connection state
            runCatching { migrateOldSingleServerToConnectionRegistry() }
            runCatching { flagExpiredCloudflareCookies() }
            launch { runCatching { refreshKomgaAdminFlags() } }
            launch { runCatching { refreshSiloAdminFlags() } }

            combine(
                flows = arrayOf(
                    prefs.serverUrl.distinctUntilChanged(),
                    prefs.username.distinctUntilChanged(),
                    prefs.activeBookSource.distinctUntilChanged(),
                    prefs.isConnected.distinctUntilChanged(),
                    prefs.hasCompletedOnboarding.distinctUntilChanged(),
                    connectionRegistry.connections.distinctUntilChanged(),
                    prefs.activeConnectionId.distinctUntilChanged(),
                )
            ) { values ->
                values.toList()
            }.collect { values ->
                val url = values[0] as String?
                val user = values[1] as String?
                val source = values[2] as BookSource
                val legacyConnected = values[3] as Boolean
                val onboardingCompleted = values[4] as Boolean
                @Suppress("UNCHECKED_CAST")
                val allConnections = values[5] as List<ProviderConnection>
                val activeConnId = values[6] as String?
                val lastSeen = prefs.lastAnnouncementSeen.first()
                _state.update {
                    it.copy(
                        activeSource = source,
                        activeServerUrl = url ?: "",
                        activeUsername = user ?: "",
                        isConnected = legacyConnected || allConnections.any { it.enabled },
                        hasCompletedOnboarding = onboardingCompleted,
                        isInitialized = true,
                        allConnections = allConnections,
                        activeConnectionId = activeConnId,
                        // Show the Discord announcement once: only for users upgrading to v10+
                        // who haven't dismissed it yet. VERSION_CODE 10 = v1.3.
                        showDiscordAnnouncement = lastSeen < com.enve.app.BuildConfig.VERSION_CODE,
                    )
                }
            }
        }
    }

    // Migrate existing single-server users to the connection registry.
    // Only runs once - after that the flag is set and we skip.
    private suspend fun migrateOldSingleServerToConnectionRegistry() {
        if (prefs.migrationCompleted.first()) return

        val oldServerUrl = prefs.serverUrl.first()
        val oldAccessToken = vault.get(CredentialVault.KEY_ACCESS_TOKEN)

        if (oldServerUrl.isNullOrBlank() || oldAccessToken.isNullOrBlank()) {
            prefs.setMigrationCompleted()
            return
        }

        val oldUsername = prefs.username.first() ?: ""
        val oldSource = prefs.activeBookSource.first()
        val connectionId = "${oldSource.name}|${oldServerUrl.trimEnd('/')}|${oldUsername.ifBlank { "token-user" }}".lowercase()

        val connection = ProviderConnection(
            id = connectionId,
            source = oldSource,
            name = "${oldSource.displayName} (Migrated)",
            serverUrl = oldServerUrl.trimEnd('/'),
            username = oldUsername,
            enabled = true,
            createdAt = System.currentTimeMillis(),
            needsReauth = false,
        )

        connectionRegistry.upsert(connection)

        // Copy legacy credentials to per-connection storage
        vault.put(CredentialVault.accessTokenKey(connectionId), oldAccessToken)
        if (oldUsername.isNotBlank()) {
            vault.put(CredentialVault.usernameKey(connectionId), oldUsername)
        }
        val oldRefreshToken = vault.get(CredentialVault.KEY_REFRESH_TOKEN)
        if (!oldRefreshToken.isNullOrBlank()) {
            vault.put(CredentialVault.refreshTokenKey(connectionId), oldRefreshToken)
        }
        val oldPassword = vault.get(CredentialVault.KEY_PASSWORD)
        if (!oldPassword.isNullOrBlank()) {
            vault.put(CredentialVault.passwordKey(connectionId), oldPassword)
        }

        prefs.setActiveConnectionId(connectionId)
        prefs.setMigrationCompleted()
    }

    fun updateServerUrl(url: String) {
        val explicitScheme = when {
            url.startsWith(UrlScheme.HTTP.prefix, ignoreCase = true) -> UrlScheme.HTTP
            url.startsWith(UrlScheme.HTTPS.prefix, ignoreCase = true) -> UrlScheme.HTTPS
            else -> null
        }
        _state.update {
            it.copy(
                serverUrl = url,
                urlScheme = explicitScheme ?: it.urlScheme,
                error = null,
            )
        }
    }

    fun updateUsername(username: String) {
        _state.update { it.copy(username = username, error = null) }
    }

    fun updatePassword(password: String) {
        _state.update { it.copy(password = password, error = null) }
    }

    fun setSelectedSource(source: BookSource) {
        val defaultUrl = defaultServerUrlFor(source)
        // Clear login fields when changing source to ensure a fresh form
        _state.update { it.copy(
            selectedSource = source,
            editingConnectionId = null,
            serverUrl = defaultUrl,
            username = "",
            password = "",
            urlScheme = UrlScheme.HTTPS,
            authMode = ConnectionAuthMode.AUTO,
            customHeaders = emptyMap(),
            serviceClientId = "",
            serviceClientSecret = "",
            mtlsEnabled = false,
            mtlsCertBytes = null,
            mtlsCertPassword = "",
            mtlsCertSubject = null,
            mtlsCertError = null,
            quickConnectCode = "",
            quickConnectPolling = false,
            cloudRootCandidates = emptyList(),
            selectedCloudRootPaths = emptyList(),
            pendingCloudRootConnectionId = null,
            error = null,
        ) }
    }

    fun prepareConnectionEdit(connectionId: String) {
        viewModelScope.launch {
            val connection = connectionRegistry.connections.first()
                .find { it.id == connectionId } ?: return@launch
            val savedPassword = vault.get(CredentialVault.passwordKey(connection.id))
                ?: vault.get(CredentialVault.accessTokenKey(connection.id))
                ?: ""
            val serviceClientId = connection.serviceClientId.ifBlank {
                vault.get(CredentialVault.serviceClientIdKey(connection.id)).orEmpty()
            }
            val serviceClientSecret = connection.serviceClientSecret.ifBlank {
                vault.get(CredentialVault.serviceClientSecretKey(connection.id)).orEmpty()
            }
            _state.update {
                it.copy(
                    selectedSource = connection.source,
                    editingConnectionId = connection.id,
                    serverUrl = connection.serverUrl,
                    username = connection.username.takeUnless { value -> value == "token-user" }.orEmpty(),
                    password = savedPassword,
                    urlScheme = connection.urlScheme,
                    authMode = connection.authMode,
                    customHeaders = connection.customHeaders,
                    serviceClientId = serviceClientId,
                    serviceClientSecret = serviceClientSecret,
                    mtlsEnabled = connection.mtlsEnabled,
                    mtlsCertBytes = null,
                    mtlsCertPassword = "",
                    mtlsCertSubject = null,
                    mtlsCertError = null,
                    quickConnectCode = "",
                    quickConnectPolling = false,
                    cloudRootCandidates = connection.cloudRootPaths,
                    selectedCloudRootPaths = connection.cloudRootPaths,
                    pendingCloudRootConnectionId = null,
                    error = null,
                )
            }
        }
    }

    private fun defaultServerUrlFor(source: BookSource): String = when (source) {
        BookSource.TORBOX -> "https://api.torbox.app/v1/api"
        BookSource.PREMIUMIZE -> "https://www.premiumize.me/api"
        BookSource.REALDEBRID -> "https://api.real-debrid.com/rest/1.0"
        else -> ""
    }

    fun updateUrlScheme(scheme: UrlScheme) {
        val current = _state.value
        val rawUrl = current.serverUrl
        val stripped = rawUrl.removePrefix("http://").removePrefix("https://")
        val newUrl = if (stripped.isNotBlank()) "${scheme.prefix}$stripped" else rawUrl
        _state.update { it.copy(urlScheme = scheme, serverUrl = newUrl, error = null) }
    }

    fun updateAuthMode(mode: ConnectionAuthMode) {
        _state.update { it.copy(authMode = mode, error = null) }
    }

    private val _quickConnect = MutableStateFlow(QuickConnectUiState())
    val quickConnect: StateFlow<QuickConnectUiState> = _quickConnect.asStateFlow()

    fun quickConnect(rawUrl: String) {
        if (rawUrl.isBlank()) return
        viewModelScope.launch {
            _quickConnect.value = QuickConnectUiState(isProbing = true)
            _quickConnect.value = when (val outcome = ServerProbe.detect(rawUrl)) {
                is ServerProbeOutcome.Identified -> QuickConnectUiState(result = outcome.server)
                is ServerProbeOutcome.OidcIssuerOnly -> QuickConnectUiState(
                    error = "That looks like a sign-in page, not a library server. Enter your server's address instead.",
                )
                is ServerProbeOutcome.Unknown -> QuickConnectUiState(
                    error = "We couldn't recognize that server. Use Set up manually to choose it yourself.",
                )
                ServerProbeOutcome.Unreachable -> QuickConnectUiState(
                    error = "Couldn't reach that address. Check the URL and that you're on the same network as the server.",
                )
            }
        }
    }

    fun consumeQuickConnectResult() {
        _quickConnect.value = QuickConnectUiState()
    }

    fun updateCustomHeader(key: String, value: String) {
        if (key.isBlank()) return
        _state.update { it.copy(customHeaders = it.customHeaders + (key.trim() to value)) }
    }

    fun stagePendingLoginCookie(cookie: String) {
        // Update the volatile cache synchronously so the next interceptor call sees the
        // value even if the DataStore write is still in flight, then persist async.
        prefs.stagePendingLoginCookie(cookie)
        viewModelScope.launch { prefs.setPendingLoginCookie(cookie) }
    }

    fun stagePendingLoginHeaders(headers: Map<String, String>, cookie: String? = null) {
        val stagedHeaders = headers.toMutableMap()
        when {
            cookie == null -> {
                val explicitCookie = stagedHeaders["Cookie"] ?: stagedHeaders["cookie"]
                if (explicitCookie.isNullOrBlank()) {
                    stagedHeaders.remove("Cookie")
                    stagedHeaders.remove("cookie")
                } else {
                    stagedHeaders["Cookie"] = explicitCookie
                    stagedHeaders.remove("cookie")
                }
            }
            cookie.isBlank() -> {
                stagedHeaders.remove("Cookie")
                stagedHeaders.remove("cookie")
            }
            else -> stagedHeaders["Cookie"] = cookie
        }
        val resolvedCookie = stagedHeaders["Cookie"]?.takeIf { it.isNotBlank() }
        if (cookie == null && resolvedCookie == null) {
            prefs.stagePendingLoginCookie("")
        } else {
            prefs.stagePendingLoginCookie(resolvedCookie.orEmpty())
        }
        prefs.stagePendingLoginHeaders(stagedHeaders)
        viewModelScope.launch {
            prefs.setPendingLoginCookie(resolvedCookie)
            prefs.setPendingLoginHeaders(stagedHeaders)
        }
    }

    private fun clearPendingLoginContext() {
        prefs.stagePendingLoginCookie(null)
        prefs.stagePendingLoginHeaders(emptyMap())
        viewModelScope.launch { prefs.clearPendingLoginContext() }
    }

    fun removeCustomHeader(key: String) {
        _state.update { it.copy(customHeaders = it.customHeaders - key) }
    }

    fun updateServiceClientId(id: String) {
        _state.update { it.copy(serviceClientId = id) }
    }

    fun updateServiceClientSecret(secret: String) {
        _state.update { it.copy(serviceClientSecret = secret) }
    }

    fun updateMtlsEnabled(enabled: Boolean) {
        _state.update { it.copy(mtlsEnabled = enabled) }
    }

    fun updateMtlsCertPassword(password: String) {
        _state.update { it.copy(mtlsCertPassword = password, mtlsCertError = null) }
        // Re-validate if bytes already staged
        val bytes = _state.value.mtlsCertBytes ?: return
        if (bytes.isNotEmpty()) validateStagedMtlsCert(bytes, password)
    }

    fun stageMtlsCert(certBytes: ByteArray) {
        val password = _state.value.mtlsCertPassword
        _state.update { it.copy(mtlsCertBytes = certBytes, mtlsCertError = null) }
        validateStagedMtlsCert(certBytes, password)
    }

    private fun validateStagedMtlsCert(certBytes: ByteArray, password: String) {
        runCatching {
            val subject = mtlsManager.validateOnly(certBytes, password)
            _state.update { it.copy(mtlsCertSubject = subject, mtlsCertError = null) }
        }.onFailure { e ->
            val msg = when {
                e.message?.contains("password") == true || e.message?.contains("mac") == true ->
                    "Incorrect certificate password"
                else -> "Invalid certificate file: ${e.message}"
            }
            _state.update { it.copy(mtlsCertSubject = null, mtlsCertError = msg) }
        }
    }

    fun clearStagedMtlsCert() {
        _state.update { it.copy(
            mtlsCertBytes = null,
            mtlsCertPassword = "",
            mtlsCertSubject = null,
            mtlsCertError = null,
        ) }
    }

    fun clearSavedMtlsCert(connectionId: String) {
        mtlsManager.clearCert(connectionId)
        _state.update { it.copy(mtlsCertSubject = null) }
    }

    fun login() {
        val current = _state.value
        if (current.serverUrl.isBlank() || current.username.isBlank() || current.password.isBlank()) {
            _state.update { it.copy(error = "All fields are required") }
            return
        }

        val normalizedUrl = if (current.selectedSource == BookSource.SMB) {
            normalizeSmbUrl(current.serverUrl)
        } else {
            normalizeUrl(current.serverUrl, current.urlScheme)
        }
        val validationError = validateServerUrl(normalizedUrl)
        if (validationError != null) {
            _state.update { it.copy(error = validationError) }
            return
        }

        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null, serverUrl = normalizedUrl) }
            val trimmedServerUrl = normalizedUrl.trimEnd('/')
            val previousSource = prefs.activeBookSource.first()
            val previousConnectionId = prefs.activeConnectionId.first()
            val previousServerUrl = prefs.serverUrl.first()
            val previousUsername = prefs.username.first()
            stagePendingLoginHeaders(current.effectiveHeaders)
            val result = if (current.selectedSource == BookSource.STORYTELLER) {
                storytellerRepository.login(
                    serverUrl = trimmedServerUrl,
                    username = current.username,
                    password = current.password,
                ).map { Unit }
            } else {
                // Surface source + server first so interceptors pick the right base/token before the network call.
                prefs.setActiveBookSource(current.selectedSource)
                prefs.saveServerInfo(trimmedServerUrl, current.username)
                repository.invalidateListCaches()
                val handler = passwordLogins[current.selectedSource]
                if (handler == null) {
                    Result.failure(Exception("Login not supported for ${current.selectedSource.displayName}"))
                } else {
                    handler.login(trimmedServerUrl, current.username, current.password)
                }
            }
            result.onSuccess {
                val connState = current.copy(serverUrl = normalizedUrl)
                val connectionId = upsertConnectionForCurrentState(connState)
                // Store per-connection creds alongside legacy ones
                storePerConnectionCredentials(connectionId, current.username, current.password)
                prefs.setActiveConnectionId(connectionId)
                _state.update {
                    it.copy(
                        isLoading = false,
                        isConnected = true,
                        password = "",
                        editingConnectionId = null,
                        activeConnectionId = connectionId,
                        loginEpoch = it.loginEpoch + 1,
                    )
                }
            }.onFailure { e ->
                if (current.selectedSource != BookSource.STORYTELLER) {
                    prefs.setActiveBookSource(previousSource)
                    prefs.setActiveConnectionId(previousConnectionId)
                    prefs.saveServerInfo(previousServerUrl.orEmpty(), previousUsername.orEmpty())
                }
                clearPendingLoginContext()
                _state.update {
                    it.copy(
                        isLoading = false,
                        error = NetworkErrorMapper.mapForUser(e.message ?: "Login failed"),
                    )
                }
            }
        }
    }

    private fun normalizeUrl(url: String, scheme: UrlScheme? = null): String {
        var cleaned = url.filter { it >= ' ' }.trim()
        if (cleaned.isEmpty()) return ""

        // Recover pasted URLs containing concatenated or nested schemes.
        val firstProtocolIndex = cleaned.indexOf("://")
        if (firstProtocolIndex != -1) {
            val secondProtocolIndex = cleaned.indexOf("://", firstProtocolIndex + 3)
            if (secondProtocolIndex != -1) {
                val secondStart = cleaned.lastIndexOf("http", secondProtocolIndex)
                if (secondStart > firstProtocolIndex) {
                    val beforeSecond = cleaned.substring(0, secondStart).trimEnd('/')
                    if (!beforeSecond.contains('.') && !beforeSecond.substringAfterLast("://").contains(':')) {
                        cleaned = cleaned.substring(secondStart).trim()
                    } else {
                        cleaned = beforeSecond.trim()
                    }
                }
            }
        }

        // Explicit scheme from the toggle is authoritative; strip any baked-in scheme so the toggle wins.
        return if (scheme != null) {
            val stripped = cleaned.removePrefix("http://").removePrefix("https://")
            "${scheme.prefix}$stripped"
        } else if (!cleaned.contains("://")) {
            "${UrlScheme.HTTPS.prefix}$cleaned"
        } else {
            cleaned
        }
    }

    private fun normalizeSmbUrl(url: String): String {
        val cleaned = url.filter { it >= ' ' }.trim()
        if (cleaned.isEmpty()) return ""
        if (cleaned.startsWith("smb://", ignoreCase = true)) return cleaned
        if (cleaned.contains("://")) return cleaned
        return "smb://${cleaned.removePrefix("//")}"
    }

    fun loginWithToken(accessToken: String) {
        val current = _state.value
        if (current.selectedSource == BookSource.GRIMMORY) {
            _state.update {
                it.copy(error = "Grimmory access tokens expire. Sign in with your username and password or SSO so Enve can renew the connection.")
            }
            return
        }
        if (accessToken.isBlank()) {
            _state.update { it.copy(error = "Access token is required") }
            return
        }

        val normalizedUrl = normalizeUrl(current.serverUrl)

        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null, serverUrl = normalizedUrl) }

            val resolvedServerUrlAndToken = if (current.selectedSource == BookSource.PLEX) {
                val plexClientId = prefs.getOrCreatePlexClientIdentifier()
                val resolved = plexPinAuth.resolvePlexServerForToken(
                    userToken = accessToken,
                    clientId = plexClientId,
                    appName = PLEX_APP_NAME,
                ).getOrNull()

                val preferredUrl = normalizedUrl.trim().takeIf { it.isNotBlank() && !it.contains("plex.tv", ignoreCase = true) }
                val effectiveUrl = preferredUrl ?: resolved?.url ?: normalizedUrl.trim().takeIf { it.isNotBlank() }
                val effectiveToken = resolved?.accessToken ?: accessToken
                effectiveUrl to effectiveToken
            } else {
                normalizedUrl.trim().takeIf { it.isNotBlank() } to accessToken
            }

            val effectiveServerUrl = resolvedServerUrlAndToken.first
            val effectiveToken = resolvedServerUrlAndToken.second

            if (effectiveServerUrl.isNullOrBlank()) {
                _state.update { it.copy(isLoading = false, error = "Server URL is required") }
                return@launch
            }

            val validationError = validateServerUrl(effectiveServerUrl)
            if (validationError != null) {
                _state.update { it.copy(isLoading = false, error = validationError) }
                return@launch
            }

            _state.update { it.copy(serverUrl = effectiveServerUrl) }
            stagePendingLoginHeaders(current.effectiveHeaders)

            val result = if (current.selectedSource == BookSource.STORYTELLER) {
                storytellerRepository.loginWithToken(
                    serverUrl = effectiveServerUrl.trimEnd('/'),
                    username = current.username,
                    accessToken = effectiveToken,
                ).map { Unit }
            } else {
                repository.loginWithToken(
                    source = current.selectedSource,
                    serverUrl = effectiveServerUrl.trimEnd('/'),
                    username = current.username,
                    accessToken = effectiveToken,
                )
            }
            result.onSuccess {
                val connState = current.copy(
                    serverUrl = effectiveServerUrl,
                    selectedSource = current.selectedSource,
                )
                val connectionId = upsertConnectionForCurrentState(connState)
                storePerConnectionCredentials(connectionId, current.username, null)
                prefs.setActiveConnectionId(connectionId)
                if (current.selectedSource == BookSource.TORBOX) {
                    prepareCloudRootSelection(connectionId)
                    return@onSuccess
                }
                _state.update {
                    it.copy(
                        isLoading = false,
                        isConnected = true,
                        password = "",
                        editingConnectionId = null,
                        activeConnectionId = connectionId,
                        loginEpoch = it.loginEpoch + 1,
                    )
                }
            }.onFailure { e ->
                clearPendingLoginContext()
                _state.update {
                    it.copy(
                        isLoading = false,
                        error = NetworkErrorMapper.mapForUser(e.message ?: "Token login failed"),
                    )
                }
            }
        }
    }

    private fun prepareCloudRootSelection(connectionId: String) {
        viewModelScope.launch {
            val roots = repository.getTorBoxRootCandidates(connectionId)
                .getOrDefault(emptyList())
            _state.update {
                it.copy(
                    isLoading = false,
                    isConnected = true,
                    password = "",
                    activeConnectionId = connectionId,
                    pendingCloudRootConnectionId = connectionId,
                    cloudRootCandidates = roots,
                    selectedCloudRootPaths = emptyList(),
                    error = null,
                )
            }
        }
    }

    fun updateCloudRootSelection(path: String, selected: Boolean) {
        val normalized = path.trim().trim('/')
        if (normalized.isBlank()) return
        _state.update { state ->
            val current = state.selectedCloudRootPaths.toMutableList()
            if (selected) {
                if (normalized !in current) current += normalized
            } else {
                current.remove(normalized)
            }
            state.copy(selectedCloudRootPaths = current)
        }
    }

    fun saveCloudRootSelection(paths: List<String>) {
        val connectionId = _state.value.pendingCloudRootConnectionId ?: return
        viewModelScope.launch {
            val allCandidates = _state.value.cloudRootCandidates
                .map { it.trim().trim('/') }
                .filter { it.isNotBlank() }
                .toSet()
            val requested = paths.map { it.trim().trim('/') }
                .filter { it.isNotBlank() }
                .distinct()
            val selected = if (requested.isNotEmpty() && allCandidates.isNotEmpty() && requested.toSet() == allCandidates) {
                emptyList()
            } else {
                collapseCloudRootSelection(requested)
            }
            connectionRegistry.getConnectionsSync()
                .find { it.id == connectionId }
                ?.let { connection ->
                    connectionRegistry.upsert(connection.copy(cloudRootPaths = selected))
                }
            runCatching { libraryCacheRepository.clearForConnection(connectionId) }
            runCatching { aggregatorRepository.invalidateCaches() }
            runCatching { libraryCacheRepository.ingestConnectionsInBackground(listOf(connectionId)) }
            _state.update {
                it.copy(
                    isLoading = false,
                    editingConnectionId = null,
                    activeConnectionId = connectionId,
                    pendingCloudRootConnectionId = null,
                    cloudRootCandidates = emptyList(),
                    selectedCloudRootPaths = emptyList(),
                    loginEpoch = it.loginEpoch + 1,
                )
            }
        }
    }

    private fun collapseCloudRootSelection(paths: List<String>): List<String> {
        val sorted = paths.map { it.trim().trim('/') }
            .filter { it.isNotBlank() }
            .distinct()
            .sortedBy { it.count { ch -> ch == '/' } }
        return sorted.filter { candidate ->
            sorted.none { parent -> parent != candidate && candidate.startsWith("$parent/") }
        }
    }

    fun startOidcLogin() {
        val current = _state.value
        if (current.serverUrl.isBlank()) {
            _state.update { it.copy(error = "Server URL is required for OIDC / SSO") }
            return
        }

        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (current.selectedSource) {
                BookSource.GRIMMORY -> {
                    val normalizedUrl = normalizeUrl(current.serverUrl, current.urlScheme)
                    val validationError = validateServerUrl(normalizedUrl)
                    if (validationError != null) {
                        _state.update { it.copy(isLoading = false, error = validationError) }
                        return@launch
                    }
                    stagePendingLoginHeaders(current.effectiveHeaders)

                    when (val result = grimmoryOidcFlow.start(normalizedUrl, current.effectiveHeaders)) {
                        is com.enve.app.data.grimmory.auth.GrimmoryOidcStart.Ready ->
                            _state.update {
                                it.copy(
                                    isLoading = false,
                                    serverUrl = result.normalizedServerUrl,
                                    browserAuthUrl = result.authUrl,
                                )
                            }
                        is com.enve.app.data.grimmory.auth.GrimmoryOidcStart.Failed ->
                            _state.update { it.copy(isLoading = false, error = result.message) }
                    }
                }

                BookSource.STORYTELLER -> {
                    val normalizedUrl = normalizeUrl(current.serverUrl, current.urlScheme)
                    val validationError = validateServerUrl(normalizedUrl)
                    if (validationError != null) {
                        _state.update { it.copy(isLoading = false, error = validationError) }
                    } else {
                        _state.update {
                            it.copy(
                                isLoading = false,
                                serverUrl = normalizedUrl,
                                browserAuthUrl = storytellerRepository.webLoginUrl(normalizedUrl),
                            )
                        }
                    }
                }

                BookSource.KOMGA -> {
                    val normalizedUrl = normalizeUrl(current.serverUrl, current.urlScheme)
                    val validationError = validateServerUrl(normalizedUrl)
                    if (validationError != null) {
                        _state.update { it.copy(isLoading = false, error = validationError) }
                        return@launch
                    }
                    val provider = current.komgaOauthProvider.trim()
                    if (provider.isBlank()) {
                        _state.update {
                            it.copy(
                                isLoading = false,
                                error = "Enter the OAuth provider name configured in Komga (e.g. \"authentik\", \"google\").",
                            )
                        }
                        return@launch
                    }
                    _state.update {
                        it.copy(
                            isLoading = false,
                            serverUrl = normalizedUrl,
                            komgaOauthProvider = provider,
                            pendingKomgaOauth = true,
                            browserAuthUrl = komgaOAuthFlow.authorizationUrl(normalizedUrl, provider),
                            browserAuthRequiredCookie = "SESSION",
                            browserAuthRequiresOriginReturn = true,
                        )
                    }
                }

                BookSource.AUDIOBOOKSHELF -> {
                    val normalizedUrl = normalizeUrl(current.serverUrl, current.urlScheme)
                    val validationError = validateServerUrl(normalizedUrl)
                    if (validationError != null) {
                        _state.update { it.copy(isLoading = false, error = validationError) }
                        return@launch
                    }

                    when (val result = absOidcFlow.start(normalizedUrl)) {
                        is com.enve.audiobookshelf.auth.AbsOidcStart.Ready ->
                            _state.update {
                                it.copy(
                                    isLoading = false,
                                    serverUrl = normalizedUrl,
                                    browserAuthUrl = result.idpAuthUrl,
                                )
                            }
                        is com.enve.audiobookshelf.auth.AbsOidcStart.Failed ->
                            _state.update { it.copy(isLoading = false, error = result.message) }
                    }
                }

                BookSource.BOOKORBIT -> {
                    val normalizedUrl = normalizeUrl(current.serverUrl, current.urlScheme)
                    val validationError = validateServerUrl(normalizedUrl)
                    if (validationError != null) {
                        _state.update { it.copy(isLoading = false, error = validationError) }
                        return@launch
                    }
                    stagePendingLoginHeaders(current.effectiveHeaders)

                    when (val result = bookOrbitOidcFlow.start(normalizedUrl, current.effectiveHeaders)) {
                        is com.enve.bookorbit.auth.BookOrbitOidcStart.Ready ->
                            _state.update {
                                it.copy(
                                    isLoading = false,
                                    serverUrl = result.serverUrl,
                                    authMode = ConnectionAuthMode.SSO,
                                    browserAuthUrl = result.authUrl,
                                )
                            }
                        is com.enve.bookorbit.auth.BookOrbitOidcStart.Failed ->
                            _state.update { it.copy(isLoading = false, error = result.message) }
                    }
                }

                else -> {
                    _state.update {
                        it.copy(
                            isLoading = false,
                            error = "${current.selectedSource.displayName} OIDC/SSO requires provider token flow. Paste token below.",
                        )
                    }
                }
            }
        }
    }

    fun consumeBrowserAuthUrl() {
        _state.update {
            it.copy(
                browserAuthUrl = null,
                browserAuthRequiredCookie = null,
                browserAuthRequiresOriginReturn = false,
            )
        }
    }

    fun setKomgaOauthProvider(value: String) {
        _state.update { it.copy(komgaOauthProvider = value.trim()) }
    }

    fun completeKomgaOauth(cookieHeader: String) {
        val current = _state.value
        if (!current.pendingKomgaOauth) return
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = komgaOAuthFlow.verifySession(current.serverUrl, cookieHeader)) {
                is com.enve.komga.auth.KomgaOAuthCompletion.Success -> {
                    val effectiveUsername = result.username.ifBlank { current.username }
                    val mergedHeaders = current.customHeaders.toMutableMap().apply {
                        put("Cookie", cookieHeader)
                    }
                    val connState = current.copy(
                        selectedSource = BookSource.KOMGA,
                        username = effectiveUsername,
                        customHeaders = mergedHeaders,
                    )
                    val connectionId = upsertConnectionForCurrentState(connState)
                    if (effectiveUsername.isNotBlank()) {
                        vault.put(CredentialVault.usernameKey(connectionId), effectiveUsername)
                    }
                    prefs.setActiveConnectionId(connectionId)
                    _state.update {
                        it.copy(
                            isLoading = false,
                            isConnected = true,
                            password = "",
                            username = effectiveUsername,
                            customHeaders = mergedHeaders,
                            pendingKomgaOauth = false,
                            browserAuthRequiresOriginReturn = false,
                            activeConnectionId = connectionId,
                            loginEpoch = it.loginEpoch + 1,
                        )
                    }
                }
                is com.enve.komga.auth.KomgaOAuthCompletion.Failed ->
                    _state.update {
                        it.copy(
                            isLoading = false,
                            pendingKomgaOauth = false,
                            browserAuthRequiresOriginReturn = false,
                            error = result.message,
                        )
                    }
            }
        }
    }

    fun cancelKomgaOauth() {
        _state.update {
            it.copy(
                pendingKomgaOauth = false,
                browserAuthRequiredCookie = null,
                browserAuthRequiresOriginReturn = false,
            )
        }
    }

    fun handleAuthCallbackUri(uri: Uri) {
        val source = _state.value.selectedSource
        val scheme = uri.scheme.orEmpty().lowercase()
        val host = uri.host.orEmpty().lowercase()
        val path = uri.path.orEmpty().lowercase()
        val isStorytellerCallback = scheme == "storyteller"
        // ABS:        audiobookshelf://oauth?…
        val isAbsOauthCallback = scheme == "audiobookshelf" && host == "oauth"
        // Grimmory:   grimmory://oauth2-callback or legacy booklore://oauth2-callback
        val isGrimmoryOauthCallback = scheme == "grimmory" || scheme == "booklore"
        val isBookOrbitOauthCallback = path.contains("oauth2-callback")

        if (isAbsOauthCallback) {
            handleAbsOauthCallback(uri)
            return
        }

        if (isGrimmoryOauthCallback) {
            handleGrimmoryOauthCallback(uri)
            return
        }

        if (isBookOrbitOauthCallback) {
            handleBookOrbitOauthCallback(uri)
            return
        }

        if (!isStorytellerCallback && host != "auth-callback" && !path.contains("auth-callback")) {
            return
        }

        val token = listOf("access_token", "token", "jwt")
            .mapNotNull { key -> uri.getQueryParameter(key)?.takeIf { it.isNotBlank() } }
            .firstOrNull()

        val callbackServerUrl = listOf("server", "serverUrl", "baseUrl")
            .mapNotNull { key -> uri.getQueryParameter(key)?.takeIf { it.isNotBlank() } }
            .firstOrNull()

        // Apply server URL immediately (before the coroutine) so it's in state when
        // the Storyteller exchange call fires - handles the case where ViewModel state
        // was reset while AuthBrowserActivity was open (e.g. process recreation).
        if (!callbackServerUrl.isNullOrBlank()) {
            _state.update { it.copy(serverUrl = callbackServerUrl) }
        }
        // Ensure selectedSource is Storyteller for the callback path even if state reset.
        if (isStorytellerCallback) {
            _state.update { it.copy(selectedSource = BookSource.STORYTELLER) }
        }

        if (!token.isNullOrBlank()) {
            viewModelScope.launch {
                _state.update { it.copy(isLoading = true, error = null) }
                val plexAdjusted = if (source == BookSource.PLEX) {
                    val plexClientId = prefs.getOrCreatePlexClientIdentifier()
                    val resolved = plexPinAuth.resolvePlexServerForToken(
                        userToken = token,
                        clientId = plexClientId,
                        appName = PLEX_APP_NAME,
                    ).getOrNull()

                    val currentUrl = _state.value.serverUrl.trim()
                    val preferredUrl = currentUrl.takeIf { it.isNotBlank() && !it.contains("plex.tv", ignoreCase = true) }
                    val effectiveUrl = preferredUrl ?: resolved?.url ?: currentUrl
                    val effectiveToken = resolved?.accessToken ?: token
                    effectiveUrl to effectiveToken
                } else {
                    // For Storyteller, prefer the server URL embedded in the callback URI
                    // (set by AuthBrowserActivity) over the possibly-stale state URL.
                    val stateUrl = _state.value.serverUrl.trim()
                    val serverUrl = callbackServerUrl?.takeIf { it.isNotBlank() } ?: stateUrl
                    serverUrl to token
                }

                val effectiveUrl = plexAdjusted.first
                val effectiveToken = plexAdjusted.second

                if (effectiveUrl.isNotBlank()) {
                    _state.update { it.copy(serverUrl = effectiveUrl) }
                }

                val loginResult = if (source == BookSource.STORYTELLER || isStorytellerCallback) {
                    storytellerRepository.exchangeAppToken(
                        serverUrl = _state.value.serverUrl.trimEnd('/'),
                        shortToken = effectiveToken,
                    ).map { Unit }
                } else {
                    repository.loginWithToken(
                        source = source,
                        serverUrl = _state.value.serverUrl.trimEnd('/'),
                        username = _state.value.username,
                        accessToken = effectiveToken,
                    )
                }

                loginResult.onSuccess {
                    val connState = _state.value.copy(
                        selectedSource = if (isStorytellerCallback) BookSource.STORYTELLER else source,
                        serverUrl = _state.value.serverUrl,
                    )
                    val connectionId = upsertConnectionForCurrentState(connState)
                    storePerConnectionCredentials(connectionId, _state.value.username, null)
                    prefs.setActiveConnectionId(connectionId)
                    _state.update { it.copy(isLoading = false, isConnected = true, password = "", activeConnectionId = connectionId, loginEpoch = it.loginEpoch + 1) }
                }.onFailure { e ->
                    _state.update { it.copy(isLoading = false, error = e.message ?: "Token login failed") }
                }
            }
            return
        }

        val code = uri.getQueryParameter("code")
        val stateParam = uri.getQueryParameter("state")
        if (code.isNullOrBlank() || stateParam.isNullOrBlank()) {
            _state.update { it.copy(error = "Authentication callback is missing code/state or token") }
            return
        }

        if (source != BookSource.GRIMMORY) {
            _state.update {
                it.copy(
                    error = "${source.displayName} callback received. Paste provider token if login did not complete automatically.",
                )
            }
            return
        }

        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            val callbackServerUrl = _state.value.serverUrl.trim()
            repository.oidcCallback(
                serverUrl = callbackServerUrl,
                code = code,
                state = stateParam,
                headers = _state.value.effectiveHeaders,
            )
                .onSuccess { username ->
                    val connState = _state.value.copy(
                        selectedSource = BookSource.GRIMMORY,
                        username = username?.takeIf { it.isNotBlank() } ?: _state.value.username,
                        authMode = ConnectionAuthMode.SSO,
                    )
                    _state.update { connState }
                    val connectionId = upsertConnectionForCurrentState(connState)
                    storePerConnectionCredentials(connectionId, connState.username, null)
                    prefs.setActiveConnectionId(connectionId)
                    _state.update {
                        it.copy(
                            isLoading = false,
                            isConnected = true,
                            password = "",
                            activeConnectionId = connectionId,
                            loginEpoch = it.loginEpoch + 1,
                        )
                    }
                }
                .onFailure { e ->
                    _state.update { it.copy(isLoading = false, error = e.message ?: "OIDC callback failed") }
                }
        }
    }

    private fun handleGrimmoryOauthCallback(uri: Uri) {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = grimmoryOidcFlow.completeCallback(uri)) {
                is com.enve.app.data.grimmory.auth.GrimmoryOidcCallback.Success -> {
                    val username = result.username?.takeIf { it.isNotBlank() } ?: _state.value.username
                    val connState = _state.value.copy(
                        selectedSource = BookSource.GRIMMORY,
                        serverUrl = result.serverUrl,
                        username = username,
                        authMode = ConnectionAuthMode.SSO,
                    )
                    _state.update {
                        it.copy(
                            selectedSource = BookSource.GRIMMORY,
                            serverUrl = result.serverUrl,
                            username = username,
                            authMode = ConnectionAuthMode.SSO,
                        )
                    }
                    val connectionId = upsertConnectionForCurrentState(connState)
                    grimmoryOidcFlow.persistTokensForConnection(connectionId)
                    prefs.setActiveConnectionId(connectionId)
                    _state.update {
                        it.copy(
                            isLoading = false,
                            isConnected = true,
                            password = "",
                            activeConnectionId = connectionId,
                            loginEpoch = it.loginEpoch + 1,
                        )
                    }
                }
                is com.enve.app.data.grimmory.auth.GrimmoryOidcCallback.NoPending ->
                    _state.update { it.copy(isLoading = false, error = "Grimmory OIDC callback received without a pending login. Try again.") }
                is com.enve.app.data.grimmory.auth.GrimmoryOidcCallback.Failed ->
                    _state.update { it.copy(isLoading = false, error = result.message) }
            }
        }
    }

    private fun handleAbsOauthCallback(uri: Uri) {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            val username = _state.value.username
            when (val result = absOidcFlow.completeCallback(uri, username)) {
                is com.enve.audiobookshelf.auth.AbsOidcCallback.Success -> {
                    val connState = _state.value.copy(
                        selectedSource = BookSource.AUDIOBOOKSHELF,
                        serverUrl = result.serverUrl,
                        username = result.username,
                    )
                    _state.update {
                        it.copy(
                            selectedSource = BookSource.AUDIOBOOKSHELF,
                            serverUrl = result.serverUrl,
                        )
                    }
                    val connectionId = upsertConnectionForCurrentState(connState)
                    absOidcFlow.persistTokensForConnection(connectionId, result.username)
                    prefs.setActiveConnectionId(connectionId)
                    _state.update {
                        it.copy(
                            isLoading = false,
                            isConnected = true,
                            password = "",
                            username = result.username.ifBlank { it.username },
                            activeConnectionId = connectionId,
                            loginEpoch = it.loginEpoch + 1,
                        )
                    }
                }
                is com.enve.audiobookshelf.auth.AbsOidcCallback.NoPending ->
                    _state.update { it.copy(isLoading = false, error = "Audiobookshelf SSO callback received without a pending login. Try again.") }
                is com.enve.audiobookshelf.auth.AbsOidcCallback.Failed ->
                    _state.update { it.copy(isLoading = false, error = result.message) }
            }
        }
    }

    private fun handleBookOrbitOauthCallback(uri: Uri) {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = bookOrbitOidcFlow.completeCallback(uri)) {
                is com.enve.bookorbit.auth.BookOrbitOidcCallback.Success -> {
                    val connState = _state.value.copy(
                        selectedSource = BookSource.BOOKORBIT,
                        serverUrl = result.serverUrl,
                        username = result.username,
                        authMode = ConnectionAuthMode.SSO,
                    )
                    _state.update {
                        it.copy(
                            selectedSource = BookSource.BOOKORBIT,
                            serverUrl = result.serverUrl,
                            username = result.username,
                            authMode = ConnectionAuthMode.SSO,
                        )
                    }
                    val connectionId = upsertConnectionForCurrentState(connState)
                    bookOrbitOidcFlow.persistTokensForConnection(connectionId, result.username)
                    prefs.setActiveConnectionId(connectionId)
                    _state.update {
                        it.copy(
                            isLoading = false,
                            isConnected = true,
                            password = "",
                            activeConnectionId = connectionId,
                            loginEpoch = it.loginEpoch + 1,
                        )
                    }
                }
                is com.enve.bookorbit.auth.BookOrbitOidcCallback.NoPending ->
                    _state.update { it.copy(isLoading = false, error = "BookOrbit SSO callback received without a pending login. Try again.") }
                is com.enve.bookorbit.auth.BookOrbitOidcCallback.Failed ->
                    _state.update { it.copy(isLoading = false, error = result.message) }
            }
        }
    }

    private fun validateServerUrl(url: String): String? {
        val trimmed = url.trim()
        if (trimmed.isBlank()) return "Server URL is required"
        // android.net.Uri.parse() is lenient and never throws - it accepts underscores in
        // hostnames, non-standard ports, and other common internal server naming patterns that
        // java.net.URI rejects with URISyntaxException, causing a false "Server URL is invalid"
        // error before any network call is ever attempted.
        val parsed = android.net.Uri.parse(trimmed)
        if (_state.value.selectedSource == BookSource.SMB) {
            return when {
                parsed.scheme != "smb" -> "SMB URL must use smb://"
                parsed.host.isNullOrBlank() -> "SMB URL must include a host"
                parsed.path.orEmpty().trim('/').isBlank() -> "SMB URL must include a share name"
                else -> null
            }
        }
        return when {
            parsed.scheme.isNullOrBlank() -> "Server URL must include http:// or https://"
            parsed.host.isNullOrBlank() -> "Server URL must include a valid host"
            parsed.scheme != "http" && parsed.scheme != "https" -> "Server URL must use http or https"
            else -> null
        }
    }

    fun logout() {
        viewModelScope.launch {
            plexPollJob?.cancel()
            plexPollJob = null
            val onboardingCompleted = _state.value.hasCompletedOnboarding
            repository.logout()
            _state.update { AuthState(hasCompletedOnboarding = onboardingCompleted, isInitialized = true) }
        }
    }

    // ─── Plex PIN OAuth ───────────────────────────────────────────────────────
    // Protocol mechanics live in [PlexPinAuthFlow]; this VM just orchestrates
    // UI state + token-acquired → connection persistence.

    fun startPlexOAuth() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }

            val session = plexPinAuthFlow.createSession(PLEX_APP_NAME).getOrElse { e ->
                _state.update { it.copy(isLoading = false, error = e.message ?: "Failed to start Plex login") }
                return@launch
            }

            _state.update {
                it.copy(
                    isLoading = false,
                    plexPinId = session.pinId,
                    plexPinCode = session.pinCode,
                    plexPolling = true,
                    browserAuthUrl = session.browserAuthUrl,
                )
            }

            plexPollJob?.cancel()
            plexPollJob = launch {
                val auth = plexPinAuthFlow.pollUntilAuthorized(session, PLEX_APP_NAME).getOrElse { e ->
                    _state.update { it.copy(plexPolling = false, plexPinId = 0L, plexPinCode = "", error = e.message ?: "Plex login failed") }
                    plexPollJob = null
                    return@launch
                }

                // Persist the plex.tv-issued user token so the Home user picker
                // can enumerate /api/v2/home/users later — per-connection vault
                // tokens get overwritten when the user switches, but this one
                // always lets us list users and switch back to the owner.
                prefs.setPlexOwnerToken(auth.userToken)

                // Register every Plex server the account has access to as its own
                // ConnectionRegistry entry (per-user product choice). The first one
                // becomes the active connection so the rest of the post-login flow
                // doesn't change.
                //
                // No fallback to plex.tv if discovery returned nothing — registering
                // plex.tv as a "server" then trying GET /library/sections against it
                // 404s the whole library load. Surface the auth-without-servers case
                // as an explicit error so the user knows to check their PMS.
                if (auth.allServers.isEmpty()) {
                    _state.update {
                        it.copy(
                            plexPolling = false,
                            plexPinId = 0L,
                            plexPinCode = "",
                            error = "Signed in to Plex but couldn't reach any of your servers. " +
                                "Check that your Plex Media Server is online and try again.",
                        )
                    }
                    plexPollJob = null
                    return@launch
                }
                val servers = auth.allServers

                var firstConnId: String? = null
                var firstServer: com.enve.plex.auth.PlexResolvedServer? = null
                servers.forEachIndexed { index, server ->
                    val name = server.name?.takeIf { it.isNotBlank() } ?: "Plex"
                    val connState = _state.value.copy(
                        selectedSource = BookSource.PLEX,
                        serverUrl = server.url,
                        username = name,
                    )
                    val connId = upsertConnectionForCurrentState(connState)
                    storePerConnectionCredentials(connId, name, null)
                    // Each Plex server gets its own server-scoped token in the vault
                    // so multi-server users can browse them independently.
                    runCatching {
                        vault.put(
                            com.enve.core.auth.CredentialVault.accessTokenKey(connId),
                            server.accessToken,
                        )
                    }
                    if (index == 0) {
                        firstConnId = connId
                        firstServer = server
                    }
                }

                val activeId = firstConnId
                val primary = firstServer
                if (activeId != null && primary != null) {
                    // ServiceLoginScreen dismisses when ALL of:
                    //   authState.isConnected == true
                    //   authState.activeSource == PLEX
                    //   authState.loginEpoch > baselineEpoch (captured at screen open)
                    //
                    // All three flow from prefs writes through the combine() above
                    // (line ~139). Write them directly here instead of through
                    // repository.loginWithToken so a future refactor of that helper
                    // can't accidentally break login dismissal — these calls are
                    // load-bearing for the UI.
                    prefs.setActiveBookSource(BookSource.PLEX)
                    prefs.saveServerInfo(
                        url = primary.url,
                        username = primary.name?.takeIf { it.isNotBlank() } ?: "Plex",
                    )
                    prefs.saveAuth(primary.accessToken, null) // flips IS_CONNECTED=true
                    prefs.setActiveConnectionId(activeId)
                    repository.invalidateListCaches()
                    _state.update {
                        it.copy(
                            plexPolling = false,
                            isConnected = true,
                            plexPinId = 0L,
                            plexPinCode = "",
                            activeConnectionId = activeId,
                            activeSource = BookSource.PLEX,
                            serverUrl = primary.url,
                            loginEpoch = it.loginEpoch + 1,
                        )
                    }
                } else {
                    _state.update { it.copy(plexPolling = false, error = "Plex login succeeded but no servers were registered.") }
                }
                plexPollJob = null
            }
        }
    }

    fun cancelPlexOAuth() {
        plexPollJob?.cancel()
        plexPollJob = null
        _state.update { it.copy(plexPolling = false, plexPinId = 0L, plexPinCode = "", error = null) }
    }

    // ─── Plex Home users ──────────────────────────────────────────────────
    // Lists the users on the owner's Plex Home and lets the user switch to
    // one. The owner token (stored by startPlexOAuth) is the call credential.
    // After a successful switch, every Plex connection in the registry gets
    // the new user-scoped token written to its vault entry, since one user
    // can have access to multiple servers and we want all of them to see the
    // switched identity.

    fun loadPlexHomeUsers() {
        viewModelScope.launch {
            _state.update { it.copy(plexHomeUsersLoading = true, plexHomeUsersError = null) }
            val owner = prefs.getPlexOwnerToken()
            if (owner.isNullOrBlank()) {
                _state.update { it.copy(plexHomeUsersLoading = false, plexHomeUsersError = "Sign in to Plex first.") }
                return@launch
            }
            val clientId = prefs.getOrCreatePlexClientIdentifier()
            val current = prefs.getPlexCurrentUserId()?.toLongOrNull()
            plexPinAuth.getHomeUsers(owner, clientId)
                .onSuccess { users ->
                    _state.update {
                        it.copy(
                            plexHomeUsers = users,
                            plexHomeUsersLoading = false,
                            plexCurrentUserId = current,
                        )
                    }
                }
                .onFailure { e ->
                    _state.update {
                        it.copy(
                            plexHomeUsersLoading = false,
                            plexHomeUsersError = e.message ?: "Couldn't load Plex users.",
                        )
                    }
                }
        }
    }

    fun switchPlexHomeUser(userId: Long, pin: String? = null) {
        viewModelScope.launch {
            _state.update { it.copy(plexHomeUsersLoading = true, plexHomeUsersError = null) }
            val owner = prefs.getPlexOwnerToken()
            if (owner.isNullOrBlank()) {
                _state.update { it.copy(plexHomeUsersLoading = false, plexHomeUsersError = "Owner token missing.") }
                return@launch
            }
            val clientId = prefs.getOrCreatePlexClientIdentifier()
            plexPinAuth.switchHomeUser(owner, clientId, userId, pin)
                .onSuccess { newToken ->
                    val plexConnections = connectionRegistry.getConnectionsSync()
                        .filter { it.source == BookSource.PLEX }
                    plexConnections.forEach { conn ->
                        vault.put(CredentialVault.accessTokenKey(conn.id), newToken)
                    }
                    prefs.setPlexCurrentUserId(userId.toString())
                    _state.update {
                        it.copy(
                            plexHomeUsersLoading = false,
                            plexCurrentUserId = userId,
                            loginEpoch = it.loginEpoch + 1,
                        )
                    }
                }
                .onFailure { e ->
                    _state.update {
                        it.copy(
                            plexHomeUsersLoading = false,
                            plexHomeUsersError = e.message ?: "Couldn't switch Plex user.",
                        )
                    }
                }
        }
    }

    fun clearPlexHomeUserError() {
        _state.update { it.copy(plexHomeUsersError = null) }
    }

    // ─── Jellyfin Quick Connect ─────────────────────────────────────────────
    // Protocol mechanics live in [JellyfinQuickConnectFlow]; this VM
    // orchestrates UI state + token-acquired → connection persistence.
    private var jellyfinPollJob: Job? = null

    fun startJellyfinQuickConnect() {
        val current = _state.value
        if (current.selectedSource != BookSource.JELLYFIN) {
            _state.update { it.copy(error = "Quick Connect is only available for Jellyfin") }
            return
        }
        val normalizedUrl = normalizeUrl(current.serverUrl, current.urlScheme)
        val validationError = validateServerUrl(normalizedUrl)
        if (validationError != null) {
            _state.update { it.copy(error = validationError) }
            return
        }

        jellyfinPollJob?.cancel()
        viewModelScope.launch {
            _state.update {
                it.copy(
                    isLoading = true,
                    error = null,
                    quickConnectCode = "",
                    quickConnectPolling = false,
                    serverUrl = normalizedUrl,
                )
            }

            // Pre-flight: friendlier upfront if QC is admin-disabled.
            // null result means the probe itself failed (network) — fall through
            // and let Initiate surface the real error.
            if (jellyfinQuickConnectFlow.isEnabled(normalizedUrl) == false) {
                _state.update {
                    it.copy(
                        isLoading = false,
                        error = "Quick Connect is disabled on this Jellyfin server. Ask your admin to enable it in Dashboard → General.",
                    )
                }
                return@launch
            }

            val session = jellyfinQuickConnectFlow.initiate(normalizedUrl).getOrElse { e ->
                _state.update {
                    it.copy(
                        isLoading = false,
                        quickConnectCode = "",
                        quickConnectPolling = false,
                        error = e.message ?: "Failed to start Jellyfin Quick Connect",
                    )
                }
                return@launch
            }

            _state.update {
                it.copy(
                    isLoading = false,
                    quickConnectCode = session.code,
                    quickConnectPolling = true,
                )
            }

            jellyfinPollJob?.cancel()
            jellyfinPollJob = launch {
                jellyfinQuickConnectFlow.pollUntilApproved(normalizedUrl, session.secret).getOrElse { e ->
                    _state.update {
                        it.copy(
                            quickConnectPolling = false,
                            quickConnectCode = "",
                            error = e.message ?: "Quick Connect poll failed",
                        )
                    }
                    jellyfinPollJob = null
                    return@launch
                }

                finishJellyfinQuickConnect(normalizedUrl, session.secret)
                jellyfinPollJob = null
            }
        }
    }

    private suspend fun finishJellyfinQuickConnect(serverUrl: String, secret: String) {
        val auth = jellyfinQuickConnectFlow.authenticate(serverUrl, secret).getOrElse { e ->
            _state.update {
                it.copy(
                    quickConnectPolling = false,
                    quickConnectCode = "",
                    error = e.message ?: "Quick Connect authentication failed",
                )
            }
            return
        }

        repository.loginWithToken(
            source = BookSource.JELLYFIN,
            serverUrl = serverUrl,
            username = auth.username,
            accessToken = auth.accessToken,
        ).onSuccess {
            val connState = _state.value.copy(
                selectedSource = BookSource.JELLYFIN,
                serverUrl = serverUrl,
                username = auth.username,
            )
            val connectionId = upsertConnectionForCurrentState(connState)
            storePerConnectionCredentials(connectionId, auth.username, null)
            if (auth.username.isNotBlank()) {
                vault.put(CredentialVault.usernameKey(connectionId), auth.username)
            }
            prefs.setActiveConnectionId(connectionId)
            _state.update {
                it.copy(
                    quickConnectPolling = false,
                    quickConnectCode = "",
                    isConnected = true,
                    password = "",
                    username = auth.username.ifBlank { it.username },
                    activeConnectionId = connectionId,
                    loginEpoch = it.loginEpoch + 1,
                )
            }
        }.onFailure { e ->
            _state.update {
                it.copy(
                    quickConnectPolling = false,
                    quickConnectCode = "",
                    error = e.message ?: "Jellyfin login failed",
                )
            }
        }
    }

    fun cancelJellyfinQuickConnect() {
        jellyfinPollJob?.cancel()
        jellyfinPollJob = null
        _state.update {
            it.copy(quickConnectPolling = false, quickConnectCode = "", error = null)
        }
    }

    fun dismissDiscordAnnouncement() {
        viewModelScope.launch {
            prefs.markAnnouncementSeen(com.enve.app.BuildConfig.VERSION_CODE)
            _state.update { it.copy(showDiscordAnnouncement = false) }
        }
    }

    fun addLocalLibrary(uri: Uri, displayName: String) {
        viewModelScope.launch {
            val uriString = uri.toString()
            val name = displayName.ifBlank { "Local Folder" }
            val connectionId = "local|$uriString".lowercase()
            _state.update {
                it.copy(
                    isLoading = true,
                    error = null,
                    importMessage = "Indexing $name... This can take a while for large libraries.",
                )
            }

            try {
                prefs.setActiveBookSource(BookSource.LOCAL)
                prefs.saveServerInfo(uriString, "Local User")
                prefs.saveAuth("local-session", null)
                prefs.setActiveConnectionId(connectionId)

                connectionRegistry.upsert(
                    ProviderConnection(
                        id = connectionId,
                        source = BookSource.LOCAL,
                        name = name,
                        serverUrl = uriString,
                        username = "Local User",
                        enabled = true,
                        lastSyncedAt = 0L,
                        needsReauth = false,
                    )
                )

                libraryCacheRepository.invalidateAndRefresh(listOf(connectionId))
                val syncedAt = System.currentTimeMillis()
                connectionRegistry.setLastSynced(connectionId, syncedAt)
                prefs.setLastSyncTime(syncedAt)

                _state.update {
                    it.copy(
                        isLoading = false,
                        isConnected = true,
                        activeSource = BookSource.LOCAL,
                        activeServerUrl = uriString,
                        activeUsername = "Local User",
                        selectedSource = BookSource.LOCAL,
                        activeConnectionId = connectionId,
                        importMessage = null,
                        loginEpoch = it.loginEpoch + 1,
                    )
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update {
                    it.copy(
                        isLoading = false,
                        importMessage = null,
                        error = NetworkErrorMapper.mapForUser(e.message),
                    )
                }
            }
        }
    }

    // Returns the deterministic connection ID so callers can store creds against it
    private suspend fun upsertConnectionForCurrentState(state: AuthState): String {
        val normalizedUrl = state.serverUrl.trim().trimEnd('/')
        val username = state.username.ifBlank { "token-user" }
        val existingConnectionId = state.editingConnectionId
        val connectionId = existingConnectionId ?: "${state.selectedSource.name}|$normalizedUrl|$username".lowercase()
        val existingConnection = existingConnectionId
            ?.let { id -> connectionRegistry.getConnectionsSync().find { it.id == id } }

        if (normalizedUrl.isBlank()) return connectionId
        if (existingConnectionId != null) {
            runCatching { libraryCacheRepository.clearForConnection(existingConnectionId) }
        }

        // Persist any staged mTLS cert to the connection's permanent store
        val certBytes = state.mtlsCertBytes
        if (state.mtlsEnabled && certBytes != null && certBytes.isNotEmpty()) {
            runCatching {
                mtlsManager.validateAndStore(connectionId, certBytes, state.mtlsCertPassword)
            }
        }

        // Store service tokens in encrypted vault
        if (state.serviceClientId.isNotBlank()) {
            vault.put(CredentialVault.serviceClientIdKey(connectionId), state.serviceClientId)
        }
        if (state.serviceClientSecret.isNotBlank()) {
            vault.put(CredentialVault.serviceClientSecretKey(connectionId), state.serviceClientSecret)
        }

        connectionRegistry.upsert(
            ProviderConnection(
                id = connectionId,
                source = state.selectedSource,
                name = buildConnectionName(state.selectedSource, normalizedUrl),
                serverUrl = normalizedUrl,
                username = username,
                enabled = true,
                createdAt = existingConnection?.createdAt ?: System.currentTimeMillis(),
                lastSyncedAt = System.currentTimeMillis(),
                needsReauth = false,
                authMode = state.authMode,
                urlScheme = state.urlScheme,
                customHeaders = state.customHeaders,
                serviceClientId = state.serviceClientId,
                serviceClientSecret = state.serviceClientSecret,
                mtlsEnabled = state.mtlsEnabled && mtlsManager.hasCert(connectionId),
                cloudRootPaths = existingConnection?.cloudRootPaths.orEmpty(),
            )
        )
        // Connection now carries the Cookie via customHeaders; the pre-login staging slot
        // is no longer needed and would otherwise leak into the next "Connect" flow.
        prefs.clearPendingLoginContext()

        if (state.selectedSource == BookSource.KOMGA) {
            viewModelScope.launch {
                runCatching {
                    val conn = connectionRegistry.connections.first().find { it.id == connectionId }
                    if (conn != null) refreshKomgaAdminFlagFor(conn)
                }
            }
        } else if (state.selectedSource == BookSource.SILO) {
            viewModelScope.launch {
                runCatching {
                    val conn = connectionRegistry.connections.first().find { it.id == connectionId }
                    if (conn != null) refreshSiloAdminFlagFor(conn)
                }
            }
        }
        // Kick a background ingest so Library / Browse / Home start populating immediately
        // instead of forcing the user to pull-to-refresh after every new server.
        runCatching { libraryCacheRepository.ingestConnectionsInBackground(listOf(connectionId)) }
        return connectionId
    }

    private fun buildConnectionName(source: BookSource, url: String): String {
        val host = runCatching { Uri.parse(url).host }.getOrNull().orEmpty().ifBlank { url }
        return "${source.displayName} ($host)"
    }

    // Store creds keyed by connection ID so each connection has its own tokens
    private fun storePerConnectionCredentials(connectionId: String, username: String?, password: String?) {
        if (!username.isNullOrBlank()) {
            vault.put(CredentialVault.usernameKey(connectionId), username)
        }
        val accessToken = vault.get(CredentialVault.KEY_ACCESS_TOKEN)
        if (!accessToken.isNullOrBlank()) {
            vault.put(CredentialVault.accessTokenKey(connectionId), accessToken)
        }
        val refreshToken = vault.get(CredentialVault.KEY_REFRESH_TOKEN)
        if (!refreshToken.isNullOrBlank()) {
            vault.put(CredentialVault.refreshTokenKey(connectionId), refreshToken)
        }
        if (!password.isNullOrBlank()) {
            vault.put(CredentialVault.passwordKey(connectionId), password)
        }
        // Mirror the just-written kosync credentials (Grimmory.login wrote them keyed by
        // serverUrl) onto the connection-keyed slot. The serverUrl-keyed slot is shared
        // across all accounts on the same host, so without this mirror two Grimmory users
        // on the same server would each see only the other's kosync creds. Sync paths
        // prefer the connection-keyed slot when ConnectionScope is set.
        val serverUrl = _state.value.serverUrl.trim().trimEnd('/')
        if (serverUrl.isNotBlank()) {
            vault.get(CredentialVault.kosyncUsernameKey(serverUrl))?.let {
                vault.put(CredentialVault.kosyncUsernameKeyForConnection(connectionId), it)
            }
            vault.get(CredentialVault.kosyncPasswordKey(serverUrl))?.let {
                vault.put(CredentialVault.kosyncPasswordKeyForConnection(connectionId), it)
            }
        }
    }

    // ─── Connection Management ────────────────────────────────────────────────

    fun listConnections(): Flow<List<ProviderConnection>> = connectionRegistry.connections

    fun checkAllConnectionsHealth() {
        if (_state.value.isCheckingHealth) return
        viewModelScope.launch {
            _state.update { it.copy(isCheckingHealth = true) }
            val result = runCatching { aggregatorRepository.checkAllConnectionsHealth() }
                .getOrElse { emptyMap() }
            _state.update { it.copy(isCheckingHealth = false, connectionHealth = result) }
        }
    }

    fun toggleConnection(connectionId: String, enabled: Boolean) {
        viewModelScope.launch {
            connectionRegistry.setEnabled(connectionId, enabled)
            if (!enabled) {
                // Disabling a connection should immediately stop its books from showing up
                // in Browse / Home counts. Cache entries get cleared; the next refresh after
                // re-enabling repopulates them. Same semantics as removeConnection without
                // touching credentials. Downloaded files on disk are NOT touched; the user
                // can still play/read them via the Downloads tab.
                runCatching { libraryCacheRepository.clearForConnection(connectionId) }
                runCatching { aggregatorRepository.invalidateCaches() }
                runCatching { aggregatorRepository.clearHomeSnapshotCache() }
            } else {
                // Re-enable: ingest just this connection so we don't re-fetch every other
                // server's books.
                runCatching { libraryCacheRepository.ingestConnectionsInBackground(listOf(connectionId)) }
            }
        }
    }

    fun switchActiveConnection(connectionId: String) {
        viewModelScope.launch {
            val connection = connectionRegistry.connections.first()
                .find { it.id == connectionId } ?: return@launch

            // Update the legacy single-server keys so interceptors/repos just work
            prefs.setActiveBookSource(connection.source)
            prefs.saveServerInfo(connection.serverUrl, connection.username)

            // Restore per-connection tokens to legacy keys
            val accessToken = vault.get(CredentialVault.accessTokenKey(connectionId))
            val refreshToken = vault.get(CredentialVault.refreshTokenKey(connectionId))
            if (!accessToken.isNullOrBlank()) {
                prefs.saveAuth(accessToken, refreshToken)
            }
            val password = vault.get(CredentialVault.passwordKey(connectionId))
            if (!password.isNullOrBlank()) {
                vault.put(CredentialVault.KEY_PASSWORD, password)
            }

            prefs.setActiveConnectionId(connectionId)
            repository.invalidateListCaches()
        }
    }

    fun removeConnection(connectionId: String) {
        viewModelScope.launch {
            // Nuke per-connection creds
            vault.remove(CredentialVault.accessTokenKey(connectionId))
            vault.remove(CredentialVault.refreshTokenKey(connectionId))
            vault.remove(CredentialVault.passwordKey(connectionId))
            vault.remove(CredentialVault.usernameKey(connectionId))
            vault.remove(CredentialVault.serviceClientIdKey(connectionId))
            vault.remove(CredentialVault.serviceClientSecretKey(connectionId))
            vault.remove(CredentialVault.kosyncUsernameKeyForConnection(connectionId))
            vault.remove(CredentialVault.kosyncPasswordKeyForConnection(connectionId))
            mtlsManager.clearCert(connectionId)

            // Drop cached books/libraries for this connection so Home/Library don't keep
            // rendering content from a server the user just deleted. Downloaded books on
            // disk (OfflineDownloadManager / ComicOfflineService) are intentionally NOT
            // touched — the user can still read/listen to those locally.
            runCatching { libraryCacheRepository.clearForConnection(connectionId) }
            runCatching { aggregatorRepository.invalidateCaches() }
            runCatching { aggregatorRepository.clearHomeSnapshotCache() }

            connectionRegistry.remove(connectionId)

            if (prefs.activeConnectionId.first() == connectionId) {
                prefs.clearActiveConnectionId()
            }

            // Wipe the legacy single-server fields once the registry empties so Settings
            // stops showing the deleted server's URL.
            if (connectionRegistry.connections.first().isEmpty()) {
                prefs.clearAuth()
            }
        }
    }

    // Cloudflare Access cookies (CF_Authorization) are short-lived JWTs (default 24h).
    // After a couple of restarts they'll be expired and every API call returns the IdP
    // challenge HTML. Decode the JWT exp claim on launch and flag connections whose
    // cookie is gone - the LibraryConnections row already shows a "Needs sign in" badge.
    private suspend fun flagExpiredCloudflareCookies() {
        val nowSec = System.currentTimeMillis() / 1000L
        val expiryBufferSec = 60L
        val current = connectionRegistry.connections.first()
        current.forEach { conn ->
            if (conn.needsReauth) return@forEach
            val cookieHeader = conn.customHeaders["Cookie"] ?: conn.customHeaders["cookie"] ?: return@forEach
            val cfJwt = extractCfAuthorizationJwt(cookieHeader) ?: return@forEach
            val exp = decodeJwtExp(cfJwt)
            if (exp > 0L && nowSec >= (exp - expiryBufferSec)) {
                connectionRegistry.upsert(conn.copy(needsReauth = true))
            }
        }
    }

    private fun extractCfAuthorizationJwt(cookieHeader: String): String? {
        cookieHeader.split(';').forEach { part ->
            val trimmed = part.trim()
            val eq = trimmed.indexOf('=')
            if (eq > 0 && trimmed.substring(0, eq).equals("CF_Authorization", ignoreCase = true)) {
                return trimmed.substring(eq + 1).takeIf { it.isNotBlank() }
            }
        }
        return null
    }

    private fun decodeJwtExp(token: String): Long = try {
        val parts = token.split(".")
        if (parts.size != 3) {
            0L
        } else {
            var base64 = parts[1].replace('-', '+').replace('_', '/')
            base64 += "=".repeat((4 - base64.length % 4) % 4)
            val payload = String(java.util.Base64.getDecoder().decode(base64), Charsets.UTF_8)
            org.json.JSONObject(payload).optLong("exp", 0L)
        }
    } catch (_: Exception) {
        0L
    }

    // Walks every Komga connection and queries /api/v1/users/me to update isAdmin. Runs in
    // ConnectionScope per connection so the request hits the right server. Failures (network,
    // 401, etc.) are silent - admin flag just isn't updated.
    private suspend fun refreshKomgaAdminFlags() {
        val current = connectionRegistry.connections.first()
            .filter { it.source == BookSource.KOMGA && it.enabled }
        current.forEach { conn -> refreshKomgaAdminFlagFor(conn) }
    }

    private suspend fun refreshKomgaAdminFlagFor(connection: ProviderConnection) {
        val resolved = withContext(
            com.enve.core.data.remote.ConnectionScope.asContextElement(connection.id)
        ) {
            komgaRepository.fetchCurrentUser()
        }
        resolved.onSuccess { user ->
            val nowAdmin = user.roles.any { it.equals("ADMIN", ignoreCase = true) }
            if (nowAdmin != connection.isAdmin) {
                connectionRegistry.upsert(connection.copy(isAdmin = nowAdmin))
            }
        }
    }

    private suspend fun refreshSiloAdminFlags() {
        val current = connectionRegistry.connections.first()
            .filter { it.source == BookSource.SILO && it.enabled }
        current.forEach { conn -> refreshSiloAdminFlagFor(conn) }
    }

    private suspend fun refreshSiloAdminFlagFor(connection: ProviderConnection) {
        val resolved = withContext(
            com.enve.core.data.remote.ConnectionScope.asContextElement(connection.id)
        ) {
            siloRepository.isCurrentUserAdmin()
        }
        resolved.onSuccess { nowAdmin ->
            if (nowAdmin != connection.isAdmin) {
                connectionRegistry.upsert(connection.copy(isAdmin = nowAdmin))
            }
        }
    }

    fun markConnectionNeedsReauth(connectionId: String) {
        viewModelScope.launch {
            val connection = connectionRegistry.connections.first()
                .find { it.id == connectionId } ?: return@launch
            connectionRegistry.upsert(connection.copy(needsReauth = true))
        }
    }

    fun clearReauthFlag(connectionId: String) {
        viewModelScope.launch {
            val connection = connectionRegistry.connections.first()
                .find { it.id == connectionId } ?: return@launch
            connectionRegistry.upsert(connection.copy(needsReauth = false))
        }
    }

    // Re-stage a fresh CF_Authorization cookie captured from the in-app browser onto an
    // existing connection. Replaces only the Cookie header so other custom headers (e.g. a
    // user-added X-Forwarded-Host) are preserved.
    fun restoreCloudflareCookieForConnection(connectionId: String, cookie: String) {
        if (cookie.isBlank()) return
        viewModelScope.launch {
            val connection = connectionRegistry.connections.first()
                .find { it.id == connectionId } ?: return@launch
            val updatedHeaders = connection.customHeaders.toMutableMap().apply {
                put("Cookie", cookie)
            }
            connectionRegistry.upsert(
                connection.copy(customHeaders = updatedHeaders, needsReauth = false)
            )
        }
    }
}
