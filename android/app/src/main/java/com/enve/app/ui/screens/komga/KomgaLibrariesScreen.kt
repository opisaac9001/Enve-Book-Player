package com.enve.app.ui.screens.komga

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.DriveFileRenameOutline
import androidx.compose.material.icons.filled.FindInPage
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.komga.dto.KomgaLibraryDto
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.viewmodel.komga.KomgaLibrariesViewModel
import com.enve.hearth.design.hearthDisplay

private val HearthRed = Color(0xFFB3453E)

@Composable
fun KomgaLibrariesScreen(onBack: () -> Unit) {
    val colors = EnveTheme.colors
    val vm: KomgaLibrariesViewModel = hiltViewModel()
    val state by vm.state.collectAsState()
    val snackbar = remember { SnackbarHostState() }
    var showCreate by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<KomgaLibraryDto?>(null) }
    var deleting by remember { mutableStateOf<KomgaLibraryDto?>(null) }
    var scanning by remember { mutableStateOf<KomgaLibraryDto?>(null) }

    LaunchedEffect(state.toast) { state.toast?.let { snackbar.showSnackbar(it); vm.consumeToast() } }
    LaunchedEffect(state.error) { state.error?.let { snackbar.showSnackbar(it); vm.consumeError() } }

    SettingsScreenLayout(animatedBackground = true) {
        Scaffold(
            containerColor = Color.Transparent,
            snackbarHost = { SnackbarHost(snackbar) },
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
                        "Libraries",
                        color = colors.primaryText,
                        style = hearthDisplay(22.sp),
                        modifier = Modifier.padding(start = DS.Spacing.MD).weight(1f),
                    )
                    IconButton(onClick = { showCreate = true }) {
                        Icon(Icons.Default.Add, contentDescription = "Add library", tint = colors.accent)
                    }
                }
            },
        ) { padding ->
            if (state.isLoading) {
                Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = colors.accent)
                }
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = DS.Spacing.LG),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD),
                ) {
                    items(state.libraries, key = { it.id }) { lib ->
                        LibraryRow(
                            library = lib,
                            onRename = { renaming = lib },
                            onScan = { scanning = lib },
                            onAnalyze = { vm.analyze(lib.id) },
                            onRefreshMetadata = { vm.refreshMetadata(lib.id) },
                            onEmptyTrash = { vm.emptyTrash(lib.id) },
                            onDelete = { deleting = lib },
                        )
                    }
                    item { Spacer(Modifier.height(80.dp)) }
                }
            }
        }
    }

    if (showCreate) {
        CreateLibraryDialog(onDismiss = { showCreate = false }, onConfirm = { name, root ->
            vm.createLibrary(name, root)
            showCreate = false
        })
    }
    renaming?.let { lib ->
        RenameDialog(
            initial = lib.name,
            onDismiss = { renaming = null },
            onConfirm = { newName ->
                vm.renameLibrary(lib.id, newName)
                renaming = null
            },
        )
    }
    deleting?.let { lib ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete library?") },
            text = { Text("Removes '${lib.name}' from Komga. The files on disk are not deleted.") },
            confirmButton = {
                TextButton(onClick = { vm.deleteLibrary(lib.id); deleting = null }) {
                    Text("Delete", color = HearthRed)
                }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
            containerColor = colors.cardBackground,
        )
    }
    scanning?.let { lib ->
        ScanDialog(
            library = lib,
            onDismiss = { scanning = null },
            onConfirm = { deep -> vm.scan(lib.id, deep); scanning = null },
        )
    }
}

@Composable
private fun LibraryRow(
    library: KomgaLibraryDto,
    onRename: () -> Unit,
    onScan: () -> Unit,
    onAnalyze: () -> Unit,
    onRefreshMetadata: () -> Unit,
    onEmptyTrash: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = EnveTheme.colors
    SettingsCard {
        Column(modifier = Modifier.padding(DS.Spacing.MD)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(library.name, color = colors.primaryText, fontWeight = FontWeight.SemiBold)
                    library.root?.let {
                        Text(it, color = colors.tertiaryText, fontSize = 11.sp)
                    }
                    if (library.unavailable == true) {
                        Text("UNAVAILABLE", color = HearthRed, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                    }
                }
                IconButton(onClick = onRename) {
                    Icon(Icons.Default.DriveFileRenameOutline, contentDescription = "Rename", tint = colors.accent)
                }
                IconButton(onClick = onDelete) {
                    Icon(Icons.Default.Delete, contentDescription = "Delete", tint = HearthRed)
                }
            }
            FlowActions(
                onScan = onScan,
                onAnalyze = onAnalyze,
                onRefreshMetadata = onRefreshMetadata,
                onEmptyTrash = onEmptyTrash,
            )
        }
    }
}

@Composable
private fun FlowActions(
    onScan: () -> Unit,
    onAnalyze: () -> Unit,
    onRefreshMetadata: () -> Unit,
    onEmptyTrash: () -> Unit,
) {
    val colors = EnveTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = DS.Spacing.SM),
        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM),
    ) {
        SmallActionChip("Scan", Icons.Default.Sync, colors.accent, onScan, Modifier.weight(1f))
        SmallActionChip("Analyze", Icons.Default.FindInPage, colors.accent, onAnalyze, Modifier.weight(1f))
    }
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = DS.Spacing.SM),
        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM),
    ) {
        SmallActionChip("Refresh metadata", Icons.Default.Refresh, colors.accent, onRefreshMetadata, Modifier.weight(1f))
        SmallActionChip("Empty trash", Icons.Default.DeleteSweep, HearthRed, onEmptyTrash, Modifier.weight(1f))
    }
}

@Composable
private fun SmallActionChip(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        color = Color.Transparent,
        contentColor = tint,
        shape = RoundedCornerShape(999.dp),
        border = BorderStroke(1.dp, tint),
        modifier = modifier,
        onClick = onClick,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
            Text(label, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun CreateLibraryDialog(onDismiss: () -> Unit, onConfirm: (String, String) -> Unit) {
    val colors = EnveTheme.colors
    var name by remember { mutableStateOf("") }
    var root by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add library") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM)) {
                OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(value = root, onValueChange = { root = it }, label = { Text("Root path") }, placeholder = { Text("/data/comics") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            }
        },
        confirmButton = { TextButton(onClick = { onConfirm(name.trim(), root.trim()) }) { Text("Create") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        containerColor = colors.cardBackground,
    )
}

@Composable
private fun RenameDialog(initial: String, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    val colors = EnveTheme.colors
    var name by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename library") },
        text = {
            OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        },
        confirmButton = { TextButton(onClick = { onConfirm(name.trim()) }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        containerColor = colors.cardBackground,
    )
}

@Composable
private fun ScanDialog(library: KomgaLibraryDto, onDismiss: () -> Unit, onConfirm: (Boolean) -> Unit) {
    val colors = EnveTheme.colors
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Scan ${library.name}") },
        text = { Text("Pick a quick scan or a deep scan that re-hashes every file.") },
        confirmButton = { TextButton(onClick = { onConfirm(false) }) { Text("Scan", color = colors.accent) } },
        dismissButton = {
            Row {
                TextButton(onClick = { onConfirm(true) }) { Text("Deep scan", color = colors.accent) }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
        containerColor = colors.cardBackground,
    )
}
