package com.enve.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.core.data.model.Book
import com.enve.app.ui.components.*
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.KOReaderHubViewModel
import com.enve.hearth.design.hearthDisplay
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@Composable
fun KOReaderHubScreen(
    onBack: () -> Unit,
    viewModel: KOReaderHubViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsState()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    var showLinks by remember { mutableStateOf(false) }

    SettingsScreenLayout(animatedBackground = EnveTheme.dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = { if (showLinks) showLinks = false else onBack() })
                Text(
                    text = if (showLinks) "Linked Books" else "KOReader",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
            }

            if (showLinks) {
                LinkedBooksContent(state, viewModel, colors, metrics)
            } else {
                HubContent(
                    state = state,
                    viewModel = viewModel,
                    colors = colors,
                    metrics = metrics,
                    onManageLinks = { showLinks = true },
                )
            }
        }
    }
}

@Composable
private fun HubContent(
    state: com.enve.app.viewmodel.KOReaderHubState,
    viewModel: KOReaderHubViewModel,
    colors: com.enve.app.ui.theme.EnveColorScheme,
    metrics: com.enve.app.ui.theme.AdaptiveMetrics,
    onManageLinks: () -> Unit,
) {
    var showPassword by remember { mutableStateOf(false) }
    val pad = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))

    SettingsHeroHeader(
        title = "KOReader",
        subtitle = if (state.isConfigured) "Connected as ${state.username}"
        else "Sync ebook progress with any KOReader-compatible server.",
        badge = if (state.isConfigured) "Linked" else null,
        icon = Icons.Default.CloudSync,
        modifier = pad,
    )

    if (state.isConfigured) {
        SettingsCard(modifier = pad) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(DS.Spacing.MD.scaled(metrics)),
                verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
            ) {
                SettingsSectionHeader(title = "Sync")
                PrimaryActionButton(
                    label = if (state.busy) "Syncing…" else "Sync Now",
                    busy = state.busy,
                    colors = colors,
                    metrics = metrics,
                ) { viewModel.syncNow() }

                val lastSync = if (state.lastSyncTime <= 0L) "Never" else
                    DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
                        .format(Instant.ofEpochMilli(state.lastSyncTime).atZone(ZoneId.systemDefault()))
                Text("Last sync: $lastSync • ${state.linkedCount} linked",
                    color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))

                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Auto-Sync", color = colors.primaryText,
                            fontSize = DS.FontSize.Subheadline.scaled(metrics), fontWeight = FontWeight.Medium)
                        Text("Push progress whenever you turn a page.",
                            color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                    }
                    Switch(checked = state.autoSync, onCheckedChange = { viewModel.setAutoSync(it) })
                }
            }
        }

        SettingsCard(modifier = pad) {
            SettingsNavigationRow(
                icon = Icons.AutoMirrored.Filled.MenuBook,
                title = "Linked Books",
                subtitle = "${state.linkedCount} linked • match by KOReader document hash",
                onClick = onManageLinks,
            )
        }
    }

    ServerConfigCard(state, viewModel, colors, metrics, showPassword) { showPassword = it }

    SettingsCard(modifier = pad) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(DS.Spacing.MD.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Info, contentDescription = null, tint = colors.accent,
                    modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
                Text("ABOUT", color = colors.tertiaryText,
                    fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.6.sp)
            }
            InfoLine("KOReader identifies books by a partial MD5 of the file. Enve computes this automatically when the ebook is downloaded.", colors, metrics)
            InfoLine("For books with no local file, open Linked Books and paste the hash shown on KOReader's Book Information page.", colors, metrics)
            InfoLine("Self-host a kosync server or use a public one like sync.koreader.rocks.", colors, metrics)
        }
    }
}

@Composable
private fun ServerConfigCard(
    state: com.enve.app.viewmodel.KOReaderHubState,
    viewModel: KOReaderHubViewModel,
    colors: com.enve.app.ui.theme.EnveColorScheme,
    metrics: com.enve.app.ui.theme.AdaptiveMetrics,
    showPassword: Boolean,
    onTogglePassword: (Boolean) -> Unit,
) {
    val fieldColors = OutlinedTextFieldDefaults.colors(
        focusedTextColor = colors.primaryText,
        unfocusedTextColor = colors.primaryText,
        focusedBorderColor = colors.accent,
    )
    val hasCreds = state.serverUrl.isNotBlank() && state.username.isNotBlank() &&
        (state.password.isNotBlank() || state.isConfigured)

    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(DS.Spacing.MD.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        ) {
            SettingsSectionHeader(
                title = "Server",
                subtitle = if (state.isConfigured) null else "Enter your kosync server credentials.",
            )
            OutlinedTextField(
                value = state.serverUrl,
                onValueChange = viewModel::setServerUrl,
                label = { Text("Server URL") },
                placeholder = { Text("https://sync.koreader.rocks") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
                colors = fieldColors,
            )
            OutlinedTextField(
                value = state.username,
                onValueChange = viewModel::setUsername,
                label = { Text("Username") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = fieldColors,
            )
            OutlinedTextField(
                value = state.password,
                onValueChange = viewModel::setPassword,
                label = { Text(if (state.isConfigured) "Password (leave blank to keep)" else "Password") },
                singleLine = true,
                visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                trailingIcon = {
                    IconButton(onClick = { onTogglePassword(!showPassword) }) {
                        Icon(
                            if (showPassword) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                            contentDescription = null, tint = colors.secondaryText,
                        )
                    }
                },
                modifier = Modifier.fillMaxWidth(),
                colors = fieldColors,
            )

            Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
                Button(
                    onClick = { viewModel.connect() },
                    enabled = hasCreds && !state.busy,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(999.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = colors.accent,
                        contentColor = Color.White,
                    ),
                ) { Text(if (state.isConfigured) "Save & Re-test" else "Connect") }

                if (!state.isConfigured) {
                    OutlinedButton(
                        onClick = { viewModel.register() },
                        enabled = hasCreds && !state.busy && state.password.isNotBlank(),
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(999.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, colors.accent),
                    ) { Text("Register", color = colors.accent) }
                }
            }

            state.statusMessage?.let {
                val mono = EnveTheme.eink.monochrome
                Text(
                    if (mono && state.statusIsError) "⚠ $it" else it,
                    color = when {
                        mono -> colors.primaryText
                        state.statusIsError -> Color(0xFFB3453E)
                        else -> Color(0xFF6F8F6A)
                    },
                    fontSize = DS.FontSize.Caption.scaled(metrics))
            }

            if (state.isConfigured) {
                TextButton(onClick = { viewModel.disconnect() }) {
                    Text("Disconnect", color = if (EnveTheme.eink.monochrome) colors.primaryText else Color(0xFFB3453E))
                }
            }
        }
    }
}

@Composable
private fun LinkedBooksContent(
    state: com.enve.app.viewmodel.KOReaderHubState,
    viewModel: KOReaderHubViewModel,
    colors: com.enve.app.ui.theme.EnveColorScheme,
    metrics: com.enve.app.ui.theme.AdaptiveMetrics,
) {
    var query by remember { mutableStateOf("") }
    var editing by remember { mutableStateOf<Book?>(null) }

    val filtered = remember(query, state.ebooks) {
        if (query.isBlank()) state.ebooks
        else state.ebooks.filter {
            it.title.contains(query, true) || (it.author?.contains(query, true) == true)
        }
    }

    OutlinedTextField(
        value = query,
        onValueChange = { query = it },
        label = { Text("Search ebooks") },
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics)),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = colors.primaryText,
            unfocusedTextColor = colors.primaryText,
            focusedBorderColor = colors.accent,
        ),
    )

    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        LazyColumn(modifier = Modifier.heightIn(max = 520.dp)) {
            items(filtered, key = { it.uniqueKey }) { book ->
                val link = state.links[book.uniqueKey]
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .enveClickable { editing = book }
                        .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(book.title, color = colors.primaryText,
                            fontSize = DS.FontSize.Subheadline.scaled(metrics),
                            fontWeight = FontWeight.Medium, maxLines = 1)
                        if (link != null) {
                            Text("${link.documentHash.take(10)}… ${if (link.isAutomatic) "(auto)" else "(manual)"}",
                                color = colors.tertiaryText, fontSize = DS.FontSize.Caption2.scaled(metrics))
                        } else {
                            Text("Not linked", color = colors.tertiaryText,
                                fontSize = DS.FontSize.Caption2.scaled(metrics))
                        }
                    }
                    Icon(
                        if (link != null) Icons.Default.Link else Icons.Default.AddLink,
                        contentDescription = null,
                        tint = if (link != null) colors.accent else colors.tertiaryText,
                        modifier = Modifier.size(20.dp),
                    )
                }
                HorizontalDivider(color = colors.separator.copy(alpha = 0.2f))
            }
        }
    }

    editing?.let { book ->
        LinkEditorDialog(
            book = book,
            existingHash = state.links[book.uniqueKey]?.documentHash ?: "",
            hasLocalFile = viewModel.hasLocalFile(book),
            onCompute = { cb -> viewModel.computeHashFromFile(book, cb) },
            onSave = { hash -> viewModel.saveLink(book, hash); editing = null },
            onRemove = if (state.links.containsKey(book.uniqueKey)) {
                { viewModel.removeLink(book); editing = null }
            } else null,
            onDismiss = { editing = null },
        )
    }
}

@Composable
private fun LinkEditorDialog(
    book: Book,
    existingHash: String,
    hasLocalFile: Boolean,
    onCompute: ((String?) -> Unit) -> Unit,
    onSave: (String) -> Unit,
    onRemove: (() -> Unit)?,
    onDismiss: () -> Unit,
) {
    var hash by remember { mutableStateOf(existingHash) }
    var computing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val valid = hash.trim().length == 32 && hash.trim().all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Link “${book.title}”") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = hash,
                    onValueChange = { hash = it; error = null },
                    label = { Text("32-char MD5 document hash") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let {
                    val mono = EnveTheme.eink.monochrome
                    Text(
                        if (mono) "⚠ $it" else it,
                        color = if (mono) EnveTheme.colors.primaryText else Color(0xFFB3453E),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                OutlinedButton(
                    onClick = {
                        computing = true
                        onCompute { result ->
                            computing = false
                            if (result != null) hash = result else error = "Could not read the local ebook file."
                        }
                    },
                    enabled = hasLocalFile && !computing,
                ) { Text(if (computing) "Computing…" else "Compute From Local File") }
                Text(
                    "Open the book in KOReader → Book Information to find its hash. Paste it here to sync even when files differ between devices.",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(hash.trim().lowercase()) }, enabled = valid) { Text("Save") }
        },
        dismissButton = {
            Row {
                if (onRemove != null) {
                    TextButton(onClick = onRemove) {
                        Text("Remove", color = if (EnveTheme.eink.monochrome) EnveTheme.colors.primaryText else Color(0xFFB3453E))
                    }
                }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

@Composable
private fun PrimaryActionButton(
    label: String,
    busy: Boolean,
    colors: com.enve.app.ui.theme.EnveColorScheme,
    metrics: com.enve.app.ui.theme.AdaptiveMetrics,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(999.dp))
            .background(colors.accent)
            .enveClickable(enabled = !busy, onClick = onClick)
            .padding(vertical = DS.Spacing.MD.scaled(metrics)),
        contentAlignment = Alignment.Center,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
            if (busy) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp)
            } else {
                Icon(Icons.Default.CloudSync, contentDescription = null, tint = Color.White,
                    modifier = Modifier.size(20.dp))
            }
            Text(label, color = Color.White,
                fontSize = DS.FontSize.Subheadline.scaled(metrics), fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun InfoLine(
    text: String,
    colors: com.enve.app.ui.theme.EnveColorScheme,
    metrics: com.enve.app.ui.theme.AdaptiveMetrics,
) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(Icons.Default.ChevronRight, contentDescription = null, tint = colors.accent,
            modifier = Modifier.size(16.dp).padding(top = 2.dp))
        Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
        Text(text, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
    }
}
