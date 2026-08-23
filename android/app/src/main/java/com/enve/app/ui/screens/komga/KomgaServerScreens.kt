package com.enve.app.ui.screens.komga

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.komga.dto.KomgaApiKeyDto
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.viewmodel.komga.KomgaServerViewModel
import com.enve.hearth.design.hearthDisplay

private val HearthRed = Color(0xFFB3453E)

@Composable
private fun KomgaScreenChrome(
    title: String,
    onBack: () -> Unit,
    actions: @Composable RowScope.() -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    val colors = EnveTheme.colors
    SettingsScreenLayout(animatedBackground = true) {
        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .statusBarsPadding()
                        .padding(horizontal = DS.Spacing.LG, vertical = DS.Spacing.SM),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ScreenBackButton(onClick = onBack)
                    Text(
                        title,
                        color = colors.primaryText,
                        style = hearthDisplay(22.sp),
                        modifier = Modifier.padding(start = DS.Spacing.MD).weight(1f),
                    )
                    actions()
                }
            },
        ) { padding -> content(padding) }
    }
}

@Composable
fun KomgaServerInfoScreen(onBack: () -> Unit) {
    val colors = EnveTheme.colors
    val vm: KomgaServerViewModel = hiltViewModel()
    val state by vm.state.collectAsState()
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(state.toast) { state.toast?.let { snackbar.showSnackbar(it); vm.consumeToast() } }
    LaunchedEffect(state.error) { state.error?.let { snackbar.showSnackbar(it); vm.consumeError() } }

    KomgaScreenChrome(
        title = "Server",
        onBack = onBack,
        actions = {
            IconButton(onClick = vm::refreshAll) {
                Icon(Icons.Default.Refresh, contentDescription = "Refresh", tint = colors.accent)
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            SnackbarHost(snackbar, modifier = Modifier.align(Alignment.BottomCenter))
            if (state.isLoading) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = colors.accent)
                }
            } else {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(DS.Spacing.LG),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD),
                ) {
                    SettingsCard {
                        Column(modifier = Modifier.padding(DS.Spacing.MD)) {
                            Text("BUILD", color = colors.tertiaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.6.sp)
                            val build = state.info?.build
                            InfoRow("Version", build?.version ?: "-")
                            InfoRow("Artifact", build?.artifact ?: "-")
                            InfoRow("Built", build?.time ?: "-")
                        }
                    }
                    SettingsCard {
                        Column(modifier = Modifier.padding(DS.Spacing.MD)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("RUNNING TASKS", color = colors.tertiaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.6.sp, modifier = Modifier.weight(1f))
                                Text("${state.tasks.size}", color = colors.tertiaryText, fontSize = 12.sp)
                            }
                            if (state.tasks.isEmpty()) {
                                Text("No tasks running.", color = colors.tertiaryText, fontSize = 12.sp)
                            } else {
                                state.tasks.forEach { task ->
                                    Text(
                                        text = task.description ?: task.type ?: "Task",
                                        color = colors.primaryText,
                                        fontSize = 13.sp,
                                        modifier = Modifier.padding(top = 4.dp),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    val colors = EnveTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = colors.tertiaryText, fontSize = 12.sp, modifier = Modifier.weight(0.4f))
        Text(value, color = colors.primaryText, fontSize = 13.sp, modifier = Modifier.weight(0.6f))
    }
}

@Composable
fun KomgaAnnouncementsScreen(onBack: () -> Unit) {
    val colors = EnveTheme.colors
    val vm: KomgaServerViewModel = hiltViewModel()
    val state by vm.state.collectAsState()
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(state.toast) { state.toast?.let { snackbar.showSnackbar(it); vm.consumeToast() } }
    LaunchedEffect(state.error) { state.error?.let { snackbar.showSnackbar(it); vm.consumeError() } }

    val items = state.announcements?.feed?.items.orEmpty()
    val unreadIds = items.filter { it.read != true }.map { it.id }

    KomgaScreenChrome(
        title = "Announcements",
        onBack = onBack,
        actions = {
            if (unreadIds.isNotEmpty()) {
                IconButton(onClick = { vm.markAnnouncementsRead(unreadIds) }) {
                    Icon(Icons.Default.DoneAll, contentDescription = "Mark all read", tint = colors.accent)
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            SnackbarHost(snackbar, modifier = Modifier.align(Alignment.BottomCenter))
            if (state.isLoading) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = colors.accent)
                }
            } else if (items.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("No announcements.", color = colors.tertiaryText)
                }
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize().padding(horizontal = DS.Spacing.LG),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD),
                ) {
                    items(items, key = { it.id }) { item ->
                        SettingsCard {
                            Column(Modifier.padding(DS.Spacing.MD)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        text = item.title.orEmpty(),
                                        color = colors.primaryText,
                                        fontWeight = FontWeight.SemiBold,
                                        modifier = Modifier.weight(1f),
                                    )
                                    if (item.read != true) {
                                        Surface(color = colors.accent.copy(alpha = 0.18f), shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp)) {
                                            Text("NEW", color = colors.accent, fontSize = 10.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp))
                                        }
                                    }
                                }
                                item.date_published?.let {
                                    Text(it, color = colors.tertiaryText, fontSize = 11.sp)
                                }
                                item.content_html?.let { html ->
                                    Text(

                                        text = html.replace(Regex("<[^>]+>"), "").trim(),
                                        color = colors.secondaryText,
                                        fontSize = 13.sp,
                                        modifier = Modifier.padding(top = 6.dp),
                                    )
                                }
                            }
                        }
                    }
                    item { Spacer(Modifier.height(80.dp)) }
                }
            }
        }
    }
}

@Composable
fun KomgaHistoryScreen(onBack: () -> Unit) {
    val colors = EnveTheme.colors
    val vm: KomgaServerViewModel = hiltViewModel()
    val state by vm.state.collectAsState()

    KomgaScreenChrome(title = "History", onBack = onBack) { padding ->
        if (state.isLoading) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = colors.accent)
            }
        } else if (state.history.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Text("No recent events.", color = colors.tertiaryText)
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = DS.Spacing.LG),
                verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM),
            ) {
                items(state.history) { event ->
                    SettingsCard {
                        Column(Modifier.padding(DS.Spacing.MD)) {
                            Text(event.type.orEmpty(), color = colors.primaryText, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                            Text(event.timestamp.orEmpty(), color = colors.tertiaryText, fontSize = 11.sp)
                            event.properties.takeIf { it.isNotEmpty() }?.let { props ->
                                props.entries.take(4).forEach { (k, v) ->
                                    Text("$k: $v", color = colors.secondaryText, fontSize = 11.sp)
                                }
                            }
                        }
                    }
                }
                item { Spacer(Modifier.height(80.dp)) }
            }
        }
    }
}

@Composable
fun KomgaApiKeysScreen(onBack: () -> Unit) {
    val colors = EnveTheme.colors
    val vm: KomgaServerViewModel = hiltViewModel()
    val state by vm.state.collectAsState()
    val context = LocalContext.current
    val snackbar = remember { SnackbarHostState() }
    var showCreate by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<KomgaApiKeyDto?>(null) }

    LaunchedEffect(state.toast) { state.toast?.let { snackbar.showSnackbar(it); vm.consumeToast() } }
    LaunchedEffect(state.error) { state.error?.let { snackbar.showSnackbar(it); vm.consumeError() } }

    KomgaScreenChrome(
        title = "API Keys",
        onBack = onBack,
        actions = {
            IconButton(onClick = { showCreate = true }) {
                Icon(Icons.Default.Add, contentDescription = "Create", tint = colors.accent)
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            SnackbarHost(snackbar, modifier = Modifier.align(Alignment.BottomCenter))
            if (state.isLoading) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = colors.accent)
                }
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize().padding(horizontal = DS.Spacing.LG),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD),
                ) {
                    items(state.apiKeys, key = { it.id }) { key ->
                        SettingsCard {
                            Row(
                                modifier = Modifier.fillMaxWidth().padding(DS.Spacing.MD),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(key.comment.orEmpty().ifBlank { "Untitled key" }, color = colors.primaryText, fontWeight = FontWeight.SemiBold)
                                    Text(key.createdDate.orEmpty(), color = colors.tertiaryText, fontSize = 11.sp)
                                }
                                IconButton(onClick = { deleting = key }) {
                                    Icon(Icons.Default.Delete, contentDescription = "Delete", tint = HearthRed)
                                }
                            }
                        }
                    }
                    item { Spacer(Modifier.height(80.dp)) }
                }
            }
        }
    }

    if (showCreate) {
        var comment by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showCreate = false },
            title = { Text("New API key") },
            text = {
                Column {
                    Text("The key value will be shown once after creation. Copy it before dismissing the dialog.", color = colors.secondaryText, fontSize = 12.sp)
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(value = comment, onValueChange = { comment = it }, label = { Text("Label / comment") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                }
            },
            confirmButton = { TextButton(onClick = { vm.createApiKey(comment.trim()); showCreate = false }) { Text("Create") } },
            dismissButton = { TextButton(onClick = { showCreate = false }) { Text("Cancel") } },
            containerColor = colors.cardBackground,
        )
    }

    state.newlyCreatedKey?.let { newKey ->
        AlertDialog(
            onDismissRequest = vm::consumeNewKey,
            title = { Text("API key created") },
            text = {
                Column {
                    Text("Save this key now. Komga only shows it once.", color = colors.secondaryText, fontSize = 12.sp)
                    Spacer(Modifier.height(8.dp))
                    Surface(color = colors.secondaryBackground, shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp)) {
                        Text(newKey.key.orEmpty(), color = colors.primaryText, fontSize = 12.sp, modifier = Modifier.padding(8.dp))
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    context.getSystemService(ClipboardManager::class.java)
                        ?.setPrimaryClip(ClipData.newPlainText("Komga API key", newKey.key.orEmpty()))
                    vm.consumeNewKey()
                }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Copy & close")
                    }
                }
            },
            dismissButton = { TextButton(onClick = vm::consumeNewKey) { Text("Close") } },
            containerColor = colors.cardBackground,
        )
    }

    deleting?.let { key ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete API key?") },
            text = { Text("Existing apps using this key will lose access immediately.") },
            confirmButton = { TextButton(onClick = { vm.deleteApiKey(key.id); deleting = null }) { Text("Delete", color = HearthRed) } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
            containerColor = colors.cardBackground,
        )
    }
}
