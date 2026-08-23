// AGENT-LOCKED
package com.enve.app.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.R
import com.enve.app.ui.auth.AuthBrowserActivity
import com.enve.app.ui.auth.AuthState
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ConnectionAuthMode
import com.enve.core.data.model.ConnectionCapability
import com.enve.core.data.model.UrlScheme
import com.enve.app.ui.components.SettingsCard
import androidx.compose.foundation.border
import com.enve.app.ui.theme.AdaptiveMetrics
import com.enve.app.ui.theme.AppTheme
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled

private val HearthEmber = Color(0xFF965A0A)
private val HearthPrimary = Color(0xFFF3EDE4)
private val HearthSecondary = Color(0xFF8F8780)
private val HearthBorder = Color.White.copy(alpha = 0.12f)

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ServiceLoginScreen(
    source: BookSource,
    authState: AuthState,
    dynamicBackgroundEnabled: Boolean = true,
    onBack: () -> Unit = {},
    onServerUrlChange: (String) -> Unit = {},
    onUsernameChange: (String) -> Unit = {},
    onPasswordChange: (String) -> Unit = {},
    onLogin: () -> Unit = {},
    onLoginWithToken: (String) -> Unit = {},
    onStartOidcLogin: () -> Unit = {},
    onStartPlexOAuth: () -> Unit = {},
    onCancelPlexOAuth: () -> Unit = {},
    onConsumeBrowserAuthUrl: () -> Unit = {},
    onLogout: () -> Unit = {},
    onAddLocalLibrary: (Uri, String) -> Unit = { _, _ -> },
    onUrlSchemeChange: (UrlScheme) -> Unit = {},
    onAuthModeChange: (ConnectionAuthMode) -> Unit = {},
    onCustomHeaderAdd: (String, String) -> Unit = { _, _ -> },
    onCustomHeaderRemove: (String) -> Unit = {},
    onServiceClientIdChange: (String) -> Unit = {},
    onServiceClientSecretChange: (String) -> Unit = {},
    onMtlsEnabledChange: (Boolean) -> Unit = {},
    onMtlsCertSelected: (ByteArray) -> Unit = {},
    onMtlsCertPasswordChange: (String) -> Unit = {},
    onMtlsCertClear: () -> Unit = {},
    onKomgaOauthProviderChange: (String) -> Unit = {},
    onCompleteKomgaOauth: (String) -> Unit = {},
    onCancelKomgaOauth: () -> Unit = {},
    onStageLoginCookie: (String) -> Unit = {},
    onStageLoginHeaders: (Map<String, String>) -> Unit = {},
    onStartQuickConnect: () -> Unit = {},
    onCancelQuickConnect: () -> Unit = {},
    onCloudRootToggle: (String, Boolean) -> Unit = { _, _ -> },
    onSaveCloudRoots: (List<String>) -> Unit = {},
) {
    val metrics = rememberAdaptiveMetrics()
    val context = LocalContext.current
    val capability = remember(source) { ConnectionCapability.forSource(source) }
    val scrollState = rememberScrollState()
    val isEditing = authState.editingConnectionId != null && authState.selectedSource == source
    val eink = EnveTheme.eink
    val title = remember(source, isEditing) {
        when {
            isEditing -> "Edit ${source.displayName}"
            source == BookSource.GRIMMORY -> "Sign in to Grimmory"
            source == BookSource.LOCAL -> "Add local files"
            else -> "Sign in to ${source.displayName}"
        }
    }

    val cfAuthLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val cookie = result.data?.getStringExtra(AuthBrowserActivity.EXTRA_RESULT_COOKIE).orEmpty()
        val ok = result.resultCode == android.app.Activity.RESULT_OK && cookie.isNotBlank()
        if (authState.pendingKomgaOauth) {
            if (ok) onCompleteKomgaOauth(cookie) else onCancelKomgaOauth()
        } else if (ok) {
            onStageLoginHeaders(
                authState.effectiveHeaders + ("Cookie" to cookie),
            )
            onCustomHeaderAdd("Cookie", cookie)

            onStageLoginCookie(cookie)
        }
    }

    LaunchedEffect(authState.browserAuthUrl, authState.browserAuthRequiredCookie) {
        val url = authState.browserAuthUrl
        if (!url.isNullOrBlank()) {
            val requiredCookie = authState.browserAuthRequiredCookie
            if (!requiredCookie.isNullOrBlank()) {
                cfAuthLauncher.launch(
                    AuthBrowserActivity.createIntent(
                        context = context,
                        url = url,
                        accent = HearthEmber.toArgb(),
                        requiredCookie = requiredCookie,
                        requireOriginReturnBeforeCookie = authState.browserAuthRequiresOriginReturn,
                    ),
                )
            } else {
                if (authState.selectedSource == BookSource.GRIMMORY) {
                    com.enve.app.ui.components.openExternalOAuthBrowser(context, url, HearthEmber)
                } else {
                    com.enve.app.ui.components.openInAppBrowser(context, url, HearthEmber)
                }
            }
            onConsumeBrowserAuthUrl()
        }
    }

    val baselineEpoch = remember(source) { authState.loginEpoch }
    LaunchedEffect(authState.loginEpoch, authState.isConnected, authState.activeSource, authState.pendingCloudRootConnectionId) {
        val waitingForCloudRootSelection = source == BookSource.TORBOX && authState.pendingCloudRootConnectionId != null
        if (authState.isConnected &&
            authState.activeSource == source &&
            authState.loginEpoch > baselineEpoch &&
            !waitingForCloudRootSelection
        ) {
            onBack()
        }
    }

    val onAuthenticateInBrowser: () -> Unit = launch@{
        val target = authState.serverUrl.takeIf { it.isNotBlank() } ?: return@launch
        val intent = AuthBrowserActivity.createIntent(context, target, HearthEmber.toArgb(), requiredCookie = "CF_Authorization")
        cfAuthLauncher.launch(intent)
    }

    EnveTheme(
        appTheme = if (eink.monochrome) AppTheme.EINK else AppTheme.OLED,
        themeColor = HearthEmber,
        dynamicBackgroundEnabled = false,
        einkProfile = eink,
    ) {
        val colors = EnveTheme.colors
        val mono = eink.monochrome
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(if (mono) colors.background else Color.Black)
                .statusBarsPadding()
                .navigationBarsPadding()
                .imePadding()
                .verticalScroll(scrollState)
                .padding(horizontal = 24.dp)
                .padding(bottom = 48.dp),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(if (mono) colors.cardBackground else Color(0xFF111113))
                        .border(1.dp, if (mono) colors.primaryText else HearthBorder, CircleShape)
                        .clickable(onClick = onBack),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        tint = if (mono) colors.primaryText else HearthPrimary,
                        modifier = Modifier.size(22.dp),
                    )
                }
                Column(Modifier.padding(start = 16.dp)) {
                    Text(
                        "BRING YOUR BOOKS",
                        color = if (mono) colors.secondaryText else HearthSecondary,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 4.sp,
                    )
                    Text(
                        title,
                        color = if (mono) colors.primaryText else HearthPrimary,
                        fontSize = 31.sp,
                        lineHeight = 35.sp,
                        fontFamily = FontFamily.Serif,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }

            Spacer(Modifier.height(30.dp))
            ServiceHeroCard(source = source, metrics = metrics)
            Spacer(Modifier.height(22.dp))

            when (source) {
                BookSource.PLEX -> PlexLoginSection(
                    authState = authState,
                    onStartPlexOAuth = onStartPlexOAuth,
                    onCancelPlexOAuth = onCancelPlexOAuth,
                    onLoginWithToken = onLoginWithToken,
                    metrics = metrics,
                )
                BookSource.LOCAL -> LocalFilesSection(
                    onAddLibrary = onAddLocalLibrary,
                    metrics = metrics,
                    isImporting = authState.isLoading,
                    importMessage = authState.importMessage,
                    error = authState.error,
                )
                else -> {
                    UnifiedLoginSection(
                        source = source,
                        capability = capability,
                        authState = authState,
                        metrics = metrics,
                        isEditing = isEditing,
                        onServerUrlChange = onServerUrlChange,
                        onUsernameChange = onUsernameChange,
                        onPasswordChange = onPasswordChange,
                        onLogin = onLogin,
                        onLoginWithToken = onLoginWithToken,
                        onStartOidcLogin = onStartOidcLogin,
                        onUrlSchemeChange = onUrlSchemeChange,
                        onAuthModeChange = onAuthModeChange,
                        onCustomHeaderAdd = onCustomHeaderAdd,
                        onCustomHeaderRemove = onCustomHeaderRemove,
                        onServiceClientIdChange = onServiceClientIdChange,
                        onServiceClientSecretChange = onServiceClientSecretChange,
                        onMtlsEnabledChange = onMtlsEnabledChange,
                        onMtlsCertSelected = onMtlsCertSelected,
                        onMtlsCertPasswordChange = onMtlsCertPasswordChange,
                        onMtlsCertClear = onMtlsCertClear,
                        onAuthenticateInBrowser = onAuthenticateInBrowser,
                        onKomgaOauthProviderChange = onKomgaOauthProviderChange,
                        onStartQuickConnect = onStartQuickConnect,
                        onCancelQuickConnect = onCancelQuickConnect,
                    )
                    if (source == BookSource.TORBOX && authState.pendingCloudRootConnectionId != null) {
                        Spacer(Modifier.height(18.dp))
                        CloudRootSelectionSection(
                            candidates = authState.cloudRootCandidates,
                            selected = authState.selectedCloudRootPaths,
                            isLoading = authState.isLoading,
                            metrics = metrics,
                            onToggle = onCloudRootToggle,
                            onSave = onSaveCloudRoots,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun UnifiedLoginSection(
    source: BookSource,
    capability: ConnectionCapability,
    authState: AuthState,
    metrics: AdaptiveMetrics,
    isEditing: Boolean,
    onServerUrlChange: (String) -> Unit,
    onUsernameChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onLogin: () -> Unit,
    onLoginWithToken: (String) -> Unit,
    onStartOidcLogin: () -> Unit,
    onUrlSchemeChange: (UrlScheme) -> Unit,
    onAuthModeChange: (ConnectionAuthMode) -> Unit,
    onCustomHeaderAdd: (String, String) -> Unit,
    onCustomHeaderRemove: (String) -> Unit,
    onServiceClientIdChange: (String) -> Unit,
    onServiceClientSecretChange: (String) -> Unit,
    onMtlsEnabledChange: (Boolean) -> Unit,
    onMtlsCertSelected: (ByteArray) -> Unit,
    onMtlsCertPasswordChange: (String) -> Unit,
    onMtlsCertClear: () -> Unit,
    onAuthenticateInBrowser: () -> Unit,
    onKomgaOauthProviderChange: (String) -> Unit,
    onStartQuickConnect: () -> Unit,
    onCancelQuickConnect: () -> Unit,
) {
    val authTabs = remember(source, capability) { authTabsFor(capability) }
    var selectedTab by remember(source) { mutableStateOf(authTabs.first()) }
    var tokenInput by remember(source) { mutableStateOf("") }
    var showPassword by remember { mutableStateOf(false) }
    var advancedExpanded by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {

        ServerUrlCard(
            source = source,
            url = authState.serverUrl,
            urlScheme = authState.urlScheme,
            metrics = metrics,
            onUrlChange = onServerUrlChange,
            onSchemeChange = onUrlSchemeChange,
        )

        if (authTabs.size > 1) {
            AuthMethodTabRow(tabs = authTabs, selected = selectedTab, onSelect = { selectedTab = it }, metrics = metrics)
        }

        SettingsCard {
            Column(
                modifier = Modifier.fillMaxWidth().padding(DS.Spacing.XL.scaled(metrics)),
                verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
            ) {
                when (selectedTab) {
                    AuthTab.CREDENTIALS -> CredentialsContent(
                        authState = authState, source = source,
                        showPassword = showPassword,
                        onTogglePassword = { showPassword = !showPassword },
                        onUsernameChange = onUsernameChange,
                        onPasswordChange = onPasswordChange,
                        onLogin = onLogin,
                        metrics = metrics,
                        isEditing = isEditing,
                        credentialsOptional = capability.credentialsOptional,
                    )
                    AuthTab.TOKEN -> TokenContent(
                        source = source, tokenInput = tokenInput,
                        onTokenChange = { tokenInput = it },
                        isLoading = authState.isLoading,
                        onConnect = { onLoginWithToken(tokenInput.trim()) },
                        metrics = metrics,
                    )
                    AuthTab.SSO -> SsoContent(
                        source = source, isLoading = authState.isLoading,
                        onConnect = onStartOidcLogin, metrics = metrics,
                        serverUrl = authState.serverUrl,
                        komgaOauthProvider = authState.komgaOauthProvider,
                        onKomgaOauthProviderChange = onKomgaOauthProviderChange,
                    )
                    AuthTab.QUICK_CONNECT -> QuickConnectContent(
                        authState = authState,
                        metrics = metrics,
                        onStart = onStartQuickConnect,
                        onCancel = onCancelQuickConnect,
                    )
                }

                authState.error?.let { err ->
                    val mono = EnveTheme.eink.monochrome
                    Text(
                        if (mono) "⚠ $err" else err,
                        color = if (mono) EnveTheme.colors.primaryText else Color(0xFFFF453A),
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
            }
        }

        if (capability.hasAdvancedOptions) {
            AdvancedOptionsSection(
                capability = capability, authState = authState,
                expanded = advancedExpanded,
                onToggle = { advancedExpanded = !advancedExpanded },
                metrics = metrics,
                onServiceClientIdChange = onServiceClientIdChange,
                onServiceClientSecretChange = onServiceClientSecretChange,
                onCustomHeaderAdd = onCustomHeaderAdd,
                onCustomHeaderRemove = onCustomHeaderRemove,
                onMtlsEnabledChange = onMtlsEnabledChange,
                onMtlsCertSelected = onMtlsCertSelected,
                onMtlsCertPasswordChange = onMtlsCertPasswordChange,
                onMtlsCertClear = onMtlsCertClear,
                onAuthenticateInBrowser = onAuthenticateInBrowser,
                browserSignInEnabled = authState.serverUrl.isNotBlank(),
            )
        }
    }
}

@Composable
private fun ServerUrlCard(
    source: BookSource,
    url: String,
    urlScheme: UrlScheme,
    metrics: AdaptiveMetrics,
    onUrlChange: (String) -> Unit,
    onSchemeChange: (UrlScheme) -> Unit,
) {
    val colors = EnveTheme.colors
    SettingsCard {
        Column(
            modifier = Modifier.fillMaxWidth().padding(DS.Spacing.LG.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
        ) {
            Text(
                if (source == BookSource.SMB) "Share" else "Server",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (source == BookSource.SMB) {
                    val displayShare = url.removePrefix("smb://")
                    OutlinedTextField(
                        value = displayShare,
                        onValueChange = { input ->
                            val stripped = input
                                .removePrefix("smb://")
                                .removePrefix("//")
                            onUrlChange(if (stripped.isBlank()) "" else "smb://$stripped")
                        },
                        placeholder = { Text("server/share/path", color = colors.tertiaryText, fontSize = DS.FontSize.Footnote.scaled(metrics)) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        modifier = Modifier.weight(1f).bringFocusedFieldIntoView(),
                        shape = RoundedCornerShape(DS.Radius.Section),
                        colors = enveTextFieldColors(),
                    )
                    return@Row
                }

                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(10.dp))
                        .background(colors.background.copy(alpha = 0.5f))
                        .padding(2.dp),
                ) {
                    UrlScheme.entries.forEach { scheme ->
                        val selected = urlScheme == scheme
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .background(if (selected) colors.accent else Color.Transparent)
                                .clickable {
                                    onSchemeChange(scheme)
                                    val host = url.removePrefix("http://").removePrefix("https://")
                                    if (host.isNotBlank()) onUrlChange("${scheme.prefix}$host")
                                }
                                .padding(horizontal = 12.dp, vertical = 7.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = scheme.displayName,
                                color = if (selected) colors.onAccent else colors.secondaryText,
                                fontSize = DS.FontSize.Footnote.scaled(metrics),
                                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                            )
                        }
                    }
                }

                val displayHost = url.removePrefix("http://").removePrefix("https://")
                OutlinedTextField(
                    value = displayHost,
                    onValueChange = { input ->

                        val stripped = input
                            .removePrefix("https://")
                            .removePrefix("http://")
                        onUrlChange("${urlScheme.prefix}$stripped")
                    },
                    placeholder = { Text("your-server.com:port", color = colors.tertiaryText, fontSize = DS.FontSize.Footnote.scaled(metrics)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.weight(1f).bringFocusedFieldIntoView(),
                    shape = RoundedCornerShape(DS.Radius.Section),
                    colors = enveTextFieldColors(),
                )
            }
        }
    }
}

private enum class AuthTab(val label: String) {
    CREDENTIALS("Credentials"),
    TOKEN("API Token"),
    SSO("SSO"),
    QUICK_CONNECT("Quick Connect"),
}

private fun authTabsFor(cap: ConnectionCapability): List<AuthTab> = buildList {
    if (cap.supportsUsernamePassword) add(AuthTab.CREDENTIALS)
    if (cap.supportsToken) add(AuthTab.TOKEN)

    if (cap.supportsOidc || cap.supportsWebLogin) add(AuthTab.SSO)
    if (cap.supportsQuickConnect) add(AuthTab.QUICK_CONNECT)
}.ifEmpty { listOf(AuthTab.CREDENTIALS) }

@Composable
private fun AuthMethodTabRow(
    tabs: List<AuthTab>,
    selected: AuthTab,
    onSelect: (AuthTab) -> Unit,
    metrics: AdaptiveMetrics,
) {
    val colors = EnveTheme.colors
    val eink = EnveTheme.eink
    val stripShape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(12.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(stripShape)
            .then(
                if (eink.suppressGradients) Modifier.border(1.dp, colors.primaryText, stripShape)
                else Modifier.background(colors.cardBackground.copy(alpha = 0.6f))
            )
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        tabs.forEach { tab ->
            val isSelected = selected == tab
            val segShape = if (eink.sharpCorners) RoundedCornerShape(2.dp) else RoundedCornerShape(9.dp)
            val segBg = when {
                !isSelected -> Color.Transparent
                eink.suppressGradients -> colors.primaryText
                else -> colors.accent.copy(alpha = 0.18f)
            }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(segShape)
                    .background(segBg)
                    .clickable { onSelect(tab) }
                    .padding(vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = tab.label,
                    color = when {
                        eink.suppressGradients && isSelected -> colors.background
                        isSelected -> colors.accent
                        else -> colors.secondaryText
                    },
                    fontSize = DS.FontSize.Footnote.scaled(metrics),
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun CredentialsContent(
    authState: AuthState,
    source: BookSource,
    showPassword: Boolean,
    onTogglePassword: () -> Unit,
    onUsernameChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onLogin: () -> Unit,
    metrics: AdaptiveMetrics,
    isEditing: Boolean,
    credentialsOptional: Boolean = false,
) {
    val focusManager = LocalFocusManager.current
    val canConnect = authState.serverUrl.isNotBlank() &&
        (credentialsOptional || (authState.username.isNotBlank() && authState.password.isNotBlank()))

    EnveTextField(
        value = authState.username,
        onValueChange = onUsernameChange,
        label = when (source) {
            BookSource.STORYTELLER -> "Username or Email"
            BookSource.KOMGA, BookSource.KAVITA, BookSource.BOOKORBIT, BookSource.SILO, BookSource.OPDS, BookSource.WEBDAV -> "Username / Email"
            else -> "Username"
        },
        placeholder = "Enter username",
        icon = Icons.Default.Person,
        keyboardType = KeyboardType.Email,
        imeAction = ImeAction.Next,
        keyboardActions = KeyboardActions(onNext = { focusManager.moveFocus(FocusDirection.Down) }),
    )
    EnvePasswordField(
        value = authState.password,
        onValueChange = onPasswordChange,
        label = "Password",
        visible = showPassword,
        onToggle = onTogglePassword,
        imeAction = ImeAction.Done,
        keyboardActions = KeyboardActions(
            onDone = {
                if (canConnect && !authState.isLoading) {
                    focusManager.clearFocus()
                    onLogin()
                }
            },
        ),
    )
    ConnectButton(
        label = if (isEditing) "Save ${source.displayName}" else "Connect ${source.displayName}",
        isLoading = authState.isLoading,
        onClick = onLogin,
        enabled = canConnect,
    )
}

@Composable
private fun TokenContent(
    source: BookSource,
    tokenInput: String,
    onTokenChange: (String) -> Unit,
    isLoading: Boolean,
    onConnect: () -> Unit,
    metrics: AdaptiveMetrics,
) {
    Text(
        "Paste your API token or personal access token.",
        color = EnveTheme.colors.secondaryText,
        fontSize = DS.FontSize.Caption.scaled(metrics),
    )
    EnveSecureTextField(value = tokenInput, onValueChange = onTokenChange, label = "API Token", placeholder = "Paste token here", icon = Icons.Default.Key)
    ConnectButton(label = "Connect with Token", isLoading = isLoading, onClick = onConnect, enabled = tokenInput.isNotBlank())
}

@Composable
private fun CloudRootSelectionSection(
    candidates: List<String>,
    selected: List<String>,
    isLoading: Boolean,
    metrics: AdaptiveMetrics,
    onToggle: (String, Boolean) -> Unit,
    onSave: (List<String>) -> Unit,
) {
    val colors = EnveTheme.colors
    val selectedSet = selected.toSet()
    var folderFilter by remember { mutableStateOf("") }
    val visibleCandidates = remember(candidates, folderFilter) {
        val query = folderFilter.trim()
        if (query.isBlank()) candidates else candidates.filter { it.contains(query, ignoreCase = true) }
    }
    SettingsCard {
        Column(
            modifier = Modifier.fillMaxWidth().padding(DS.Spacing.XL.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
                Icon(Icons.Default.Folder, contentDescription = null, tint = colors.accent)
                Text(
                    "Choose TorBox folders",
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Title3.scaled(metrics),
                    fontWeight = FontWeight.Bold,
                )
            }
            Text(
                "Select one or more folders to include. Leave it empty to show every audiobook TorBox returns.",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )

            if (candidates.isEmpty()) {
                Text(
                    "No folder paths were found yet. You can still save TorBox and Enve will show all audio files.",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Footnote.scaled(metrics),
                )
            } else {
                OutlinedTextField(
                    value = folderFilter,
                    onValueChange = { folderFilter = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                    placeholder = { Text("Search folders") },
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = colors.primaryText,
                        unfocusedTextColor = colors.primaryText,
                        focusedBorderColor = colors.accent,
                        unfocusedBorderColor = HearthBorder,
                        focusedContainerColor = colors.background.copy(alpha = 0.35f),
                        unfocusedContainerColor = colors.background.copy(alpha = 0.25f),
                        cursorColor = colors.accent,
                    ),
                )
                Column(verticalArrangement = Arrangement.spacedBy(6.dp.scaled(metrics))) {
                    visibleCandidates.forEach { path ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(colors.background.copy(alpha = 0.45f))
                                .clickable { onToggle(path, path !in selectedSet) }
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Checkbox(
                                checked = path in selectedSet,
                                onCheckedChange = { checked -> onToggle(path, checked) },
                                colors = CheckboxDefaults.colors(
                                    checkedColor = colors.accent,
                                    uncheckedColor = colors.secondaryText,
                                ),
                            )
                            Text(
                                path,
                                color = colors.primaryText,
                                fontSize = DS.FontSize.Footnote.scaled(metrics),
                                maxLines = 2,
                            )
                        }
                    }
                    if (visibleCandidates.isEmpty()) {
                        Text(
                            "No folders match that search.",
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                        )
                    } else if (visibleCandidates.size != candidates.size) {
                        Text(
                            "Showing ${visibleCandidates.size} of ${candidates.size} folders.",
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                        )
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
                OutlinedButton(
                    onClick = { onSave(emptyList()) },
                    enabled = !isLoading,
                    modifier = Modifier.weight(1f).height(52.dp),
                    shape = RoundedCornerShape(16.dp),
                ) {
                    Text("Use All", fontWeight = FontWeight.SemiBold)
                }
                Button(
                    onClick = { onSave(selected) },
                    enabled = !isLoading,
                    modifier = Modifier.weight(1f).height(52.dp),
                    shape = RoundedCornerShape(16.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = colors.accent),
                ) {
                    Text("Save Folders", fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun SsoContent(
    source: BookSource,
    isLoading: Boolean,
    onConnect: () -> Unit,
    metrics: AdaptiveMetrics,
    serverUrl: String,
    komgaOauthProvider: String,
    onKomgaOauthProviderChange: (String) -> Unit,
) {
    val colors = EnveTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics))) {
        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        ) {
            Icon(Icons.Default.OpenInBrowser, null, tint = colors.accent, modifier = Modifier.size(20.dp).padding(top = 2.dp))
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    if (source == BookSource.STORYTELLER) "Web Login (SSO)" else "Single Sign-On (SSO)",
                    color = colors.primaryText, fontWeight = FontWeight.SemiBold,
                )
                Text(
                    when (source) {
                        BookSource.STORYTELLER -> "Opens the Storyteller login page in a browser. Use this for Authentik, OIDC, or other SSO providers configured on your server."
                        BookSource.KOMGA -> "Opens your OAuth provider in a browser. Komga uses Spring Security OAuth2 - enter the registration ID configured in your server's application.yml below."
                        else -> "Opens your SSO provider in a browser. After signing in, you'll be redirected back to Enve automatically."
                    },
                    color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
        }
        if (source == BookSource.KOMGA) {
            EnveTextField(
                value = komgaOauthProvider,
                onValueChange = onKomgaOauthProviderChange,
                label = "Provider registration ID",
                placeholder = "authentik, google, microsoft, …",
                icon = Icons.Default.AccountCircle,
            )
        }

        val redirectUri = when (source) {
            BookSource.AUDIOBOOKSHELF -> com.enve.core.auth.OAuthRedirectUris.AUDIOBOOKSHELF
            BookSource.GRIMMORY -> com.enve.core.auth.OAuthRedirectUris.GRIMMORY
            BookSource.BOOKORBIT -> serverUrl.trim().trimEnd('/').takeIf { it.isNotBlank() }?.let { "$it/oauth2-callback" }
            else -> null
        }
        if (redirectUri != null) {
            val context = LocalContext.current
            Surface(
                shape = RoundedCornerShape(10.dp),
                color = colors.secondaryBackground.copy(alpha = 0.6f),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    modifier = Modifier.padding(
                        horizontal = DS.Spacing.MD.scaled(metrics),
                        vertical = DS.Spacing.SM.scaled(metrics),
                    ),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        "Redirect URI to whitelist on your IdP",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                        fontWeight = FontWeight.SemiBold,
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                    ) {
                        Text(
                            redirectUri,
                            color = colors.primaryText,
                            fontSize = DS.FontSize.Caption.scaled(metrics),
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = {
                            context.getSystemService(ClipboardManager::class.java)
                                ?.setPrimaryClip(ClipData.newPlainText("Redirect URI", redirectUri))
                        }) {
                            Text("Copy", color = colors.accent, fontSize = DS.FontSize.Caption.scaled(metrics))
                        }
                    }
                }
            }
        }
        ConnectButton(
            label = when {
                isLoading -> "Opening Browser…"
                source == BookSource.STORYTELLER -> "Sign In with Web Login"
                else -> "Sign In with SSO"
            },
            isLoading = isLoading,
            onClick = onConnect,
            enabled = source != BookSource.KOMGA || komgaOauthProvider.isNotBlank(),
        )
    }
}

@Composable
private fun QuickConnectContent(
    authState: AuthState,
    metrics: AdaptiveMetrics,
    onStart: () -> Unit,
    onCancel: () -> Unit,
) {
    val colors = EnveTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics))) {
        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        ) {
            Icon(Icons.Default.QrCode, null, tint = colors.accent, modifier = Modifier.size(20.dp).padding(top = 2.dp))
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Quick Connect", color = colors.primaryText, fontWeight = FontWeight.SemiBold)
                Text(
                    "Authorize from your Jellyfin web interface without entering a password. Quick Connect must be enabled by an admin in Dashboard → General.",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
        }
        if (authState.quickConnectCode.isNotBlank()) {
            Surface(shape = RoundedCornerShape(12.dp), color = colors.accent.copy(alpha = 0.1f), modifier = Modifier.fillMaxWidth()) {
                Column(
                    modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics)),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                ) {
                    Text("Enter this code in Jellyfin", color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                    Text(
                        authState.quickConnectCode,
                        color = colors.accent,
                        fontSize = DS.FontSize.Title.scaled(metrics),
                        fontWeight = FontWeight.Bold,
                        letterSpacing = DS.FontSize.Caption2.scaled(metrics) * 0.55f,
                    )
                    if (authState.quickConnectPolling) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(modifier = Modifier.size(14.dp), color = colors.accent, strokeWidth = 2.dp)
                            Text("Waiting for authorization…", color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                        }
                    }
                }
            }
            TextButton(
                onClick = onCancel,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Cancel", color = colors.secondaryText, fontSize = DS.FontSize.Body.scaled(metrics))
            }
        } else {
            Text(
                "Tap Start Quick Connect - Enve will display a 6-character code. Open Jellyfin in any signed-in browser/device, navigate to your user menu → Quick Connect, and enter the code to authorize this device.",
                color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics),
            )
            ConnectButton(
                label = if (authState.isLoading) "Starting…" else "Start Quick Connect",
                isLoading = authState.isLoading,
                onClick = onStart,
                enabled = authState.serverUrl.isNotBlank(),
            )
        }
    }
}

@Composable
private fun ServiceHeroCard(source: BookSource, metrics: AdaptiveMetrics) {
    val colors = EnveTheme.colors
    val mono = EnveTheme.eink.monochrome
    val meta = remember(source) {
        serviceInfo(source, accent = HearthEmber)
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(if (mono) colors.cardBackground else Color(0xFF111113))
            .border(1.dp, if (mono) colors.primaryText else HearthBorder, RoundedCornerShape(20.dp))
            .padding(16.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(56.dp.scaled(metrics))
                    .clip(RoundedCornerShape(14.dp))
                    .background(if (mono) colors.background else Color.Black)
                    .border(1.dp, if (mono) colors.primaryText else HearthBorder, RoundedCornerShape(14.dp)),
                contentAlignment = Alignment.Center,
            ) {
                if (meta.iconRes != null) {
                    Image(painter = painterResource(meta.iconRes), contentDescription = null, modifier = Modifier.size(34.dp.scaled(metrics)), contentScale = ContentScale.Fit)
                } else if (meta.iconVector != null) {
                    Icon(meta.iconVector, null, tint = if (mono) colors.primaryText else meta.tint, modifier = Modifier.size(32.dp.scaled(metrics)))
                } else {
                    com.enve.app.ui.components.BookSourceIcon(
                        source = source,
                        tint = if (mono) colors.primaryText else meta.tint,
                        modifier = Modifier.size(34.dp.scaled(metrics)),
                    )
                }
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(source.displayName, color = if (mono) colors.primaryText else HearthPrimary, fontSize = DS.FontSize.Headline.scaled(metrics), fontWeight = FontWeight.SemiBold)
                Text(meta.description, color = if (mono) colors.secondaryText else HearthSecondary, fontSize = DS.FontSize.Caption.scaled(metrics), lineHeight = 17.sp)
            }
        }
    }
}

@Composable
private fun PlexLoginSection(
    authState: AuthState, onStartPlexOAuth: () -> Unit, onCancelPlexOAuth: () -> Unit,
    onLoginWithToken: (String) -> Unit, metrics: AdaptiveMetrics,
) {
    val colors = EnveTheme.colors
    var tokenInput by remember { mutableStateOf("") }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {
        SettingsCard {
            Column(modifier = Modifier.fillMaxWidth().padding(DS.Spacing.XL.scaled(metrics)), verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics))) {
                if (authState.plexPolling) {
                    Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = colors.accent)
                        Column {
                            Text("Waiting for Plex authorization…", color = colors.primaryText, fontWeight = FontWeight.SemiBold)
                            Text("Approve in the browser window", color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                        }
                    }
                    OutlinedButton(onClick = onCancelPlexOAuth, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp)) {
                        Text("Cancel", color = colors.secondaryText)
                    }
                } else {
                    val mono = EnveTheme.eink.monochrome
                    Button(
                        onClick = onStartPlexOAuth, enabled = !authState.isLoading,
                        modifier = Modifier.fillMaxWidth().height(54.dp), shape = RoundedCornerShape(18.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = if (mono) colors.accent else Color(0xFFE5A319),
                            contentColor = if (mono) colors.onAccent else Color.White,
                        ),
                    ) { Text("Sign in with Plex", fontWeight = FontWeight.SemiBold) }
                }
            }
        }

        SettingsCard {
            Column(modifier = Modifier.fillMaxWidth().padding(DS.Spacing.XL.scaled(metrics)), verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics))) {
                Text("Or connect with a Plex token", color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics), fontWeight = FontWeight.SemiBold)
                EnveSecureTextField(value = tokenInput, onValueChange = { tokenInput = it }, label = "Plex Token", placeholder = "X-Plex-Token", icon = Icons.Default.Key)
                ConnectButton(label = "Connect with Token", isLoading = authState.isLoading, onClick = { onLoginWithToken(tokenInput.trim()) }, enabled = tokenInput.isNotBlank())
            }
        }

        authState.error?.let {
            val mono = EnveTheme.eink.monochrome
            Text(
                if (mono) "⚠ $it" else it,
                color = if (mono) colors.primaryText else Color(0xFFFF453A),
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
        }
    }
}

@Composable
private fun LocalFilesSection(
    onAddLibrary: (Uri, String) -> Unit,
    metrics: AdaptiveMetrics,
    isImporting: Boolean,
    importMessage: String?,
    error: String?,
) {
    val colors = EnveTheme.colors
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) {
            context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            onAddLibrary(uri, uri.lastPathSegment ?: "Local Folder")
        }
    }
    SettingsCard {
        Column(modifier = Modifier.fillMaxWidth().padding(DS.Spacing.XL.scaled(metrics)), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics))) {
            Icon(Icons.Default.FolderOpen, null, tint = colors.accent, modifier = Modifier.size(64.dp))
            Text("Add Local Library", color = colors.primaryText, fontSize = DS.FontSize.Title3.scaled(metrics), fontWeight = FontWeight.Bold)
            Text("Select a folder on your device to scan for audiobooks and ebooks.", color = colors.secondaryText, fontSize = DS.FontSize.Body.scaled(metrics), textAlign = TextAlign.Center)
            if (isImporting) {
                LinearProgressIndicator(
                    modifier = Modifier.fillMaxWidth(),
                    color = colors.accent,
                    trackColor = colors.separator,
                )
                Text(
                    importMessage ?: "Indexing library...",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                    textAlign = TextAlign.Center,
                )
            }
            if (!error.isNullOrBlank()) {
                val mono = EnveTheme.eink.monochrome
                Text(
                    if (mono) "⚠ $error" else error,
                    color = if (mono) colors.primaryText else Color(0xFFFF453A),
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                    textAlign = TextAlign.Center,
                )
            }
            Spacer(Modifier.height(DS.Spacing.SM))
            Button(onClick = { launcher.launch(null) }, enabled = !isImporting, modifier = Modifier.fillMaxWidth().height(54.dp), shape = RoundedCornerShape(18.dp), colors = ButtonDefaults.buttonColors(containerColor = colors.accent)) {
                Text(
                    if (isImporting) "Indexing..." else "Select Folder",
                    fontWeight = FontWeight.SemiBold,
                    fontSize = DS.FontSize.Headline.scaled(metrics),
                )
            }
        }
    }
}

private data class ServiceMeta(val iconRes: Int? = null, val iconVector: ImageVector? = null, val tint: Color, val description: String)

private fun serviceInfo(source: BookSource, accent: Color): ServiceMeta = when (source) {
    BookSource.GRIMMORY -> ServiceMeta(tint = accent, description = "Connect to your Grimmory server.")
    BookSource.STORYTELLER -> ServiceMeta(tint = Color(0xFF0EA5A4), description = "Connect to your Storyteller server for audiobook, ebook, and progress sync.")
    BookSource.AUDIOBOOKSHELF -> ServiceMeta(iconRes = R.drawable.ic_audiobookshelf, tint = Color(0xFFC8A45A), description = "Connect to your self-hosted Audiobookshelf server.")
    BookSource.JELLYFIN -> ServiceMeta(iconRes = R.drawable.ic_jellyfin, tint = Color(0xFF9C6BDB), description = "Connect to your Jellyfin media server. Supports Quick Connect.")
    BookSource.PLEX -> ServiceMeta(iconRes = R.drawable.ic_plex, tint = Color(0xFFE5A319), description = "Sign in with your Plex account. Enve will never see your Plex password.")
    BookSource.EMBY -> ServiceMeta(iconRes = R.drawable.ic_emby, tint = Color(0xFF4CAF7D), description = "Connect to your Emby media server.")
    BookSource.KOMGA -> ServiceMeta(iconRes = R.drawable.ic_komga, tint = Color(0xFF6C7AE0), description = "Komga is a self-hosted comics and manga server.")
    BookSource.KAVITA -> ServiceMeta(iconRes = R.drawable.ic_kavita, tint = Color(0xFF4CAF7D), description = "Kavita is a self-hosted reading server.")
    BookSource.BOOKORBIT -> ServiceMeta(iconRes = R.drawable.ic_bookorbit, tint = Color(0xFF4F8BFF), description = "Connect to your self-hosted BookOrbit server for ebooks, audiobooks, and progress sync.")
    BookSource.SILO -> ServiceMeta(iconRes = R.drawable.ic_silo, tint = Color(0xFF14B8A6), description = "Connect to your Silo server for ebooks, audiobooks, progress sync, chapters, and annotations.")
    BookSource.OPDS -> ServiceMeta(iconRes = R.drawable.ic_opds, tint = Color(0xFF26A69A), description = "Connect to any OPDS-compatible catalog feed.")
    BookSource.WEBDAV -> ServiceMeta(iconRes = R.drawable.ic_webdav, tint = Color(0xFF15B8D6), description = "Connect to a WebDAV server such as Nextcloud or OwnCloud.")
    BookSource.TORBOX -> ServiceMeta(iconRes = R.drawable.ic_torbox, tint = Color(0xFF00B8D9), description = "Connect to your TorBox cloud and choose audiobook folders.")
    BookSource.PREMIUMIZE -> ServiceMeta(iconRes = R.drawable.ic_premiumize, tint = Color(0xFF2E7D32), description = "Connect to your Premiumize cloud files with an API token.")
    BookSource.REALDEBRID -> ServiceMeta(iconRes = R.drawable.ic_realdebrid, tint = Color(0xFF1976D2), description = "Connect to your Real-Debrid downloads with an API token.")
    BookSource.SMB -> ServiceMeta(iconVector = Icons.Default.Router, tint = Color(0xFF16B5E4), description = "Connect to a Windows share or Samba server.")
    BookSource.LOCAL -> ServiceMeta(iconVector = Icons.Default.Folder, tint = Color(0xFF1E88E5), description = "Import audiobooks and ebooks from your device.")
}
