package com.enve.app.ui.screens.komga

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DriveFileRenameOutline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.komga.dto.KomgaCollectionDto
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.viewmodel.komga.KomgaCollectionsViewModel
import com.enve.hearth.design.hearthDisplay

private val HearthRed = Color(0xFFB3453E)

@Composable
fun KomgaCollectionsScreen(onBack: () -> Unit) {
    val colors = EnveTheme.colors
    val vm: KomgaCollectionsViewModel = hiltViewModel()
    val state by vm.state.collectAsState()
    val snackbar = remember { SnackbarHostState() }
    var showCreate by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<KomgaCollectionDto?>(null) }
    var deleting by remember { mutableStateOf<KomgaCollectionDto?>(null) }

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
                        "Collections",
                        color = colors.primaryText,
                        style = hearthDisplay(22.sp),
                        modifier = Modifier.padding(start = DS.Spacing.MD).weight(1f),
                    )
                    IconButton(onClick = { showCreate = true }) {
                        Icon(Icons.Default.Add, contentDescription = "Add", tint = colors.accent)
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
                    items(state.collections, key = { it.id }) { col ->
                        SettingsCard {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(DS.Spacing.MD),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(col.name, color = colors.primaryText, fontWeight = FontWeight.SemiBold)
                                    Text(
                                        text = "${col.seriesIds?.size ?: 0} series",
                                        color = colors.tertiaryText,
                                        fontSize = 11.sp,
                                    )
                                }
                                IconButton(onClick = { renaming = col }) {
                                    Icon(Icons.Default.DriveFileRenameOutline, contentDescription = "Rename", tint = colors.accent)
                                }
                                IconButton(onClick = { deleting = col }) {
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
        var name by remember { mutableStateOf("") }
        var ordered by remember { mutableStateOf(false) }
        AlertDialog(
            onDismissRequest = { showCreate = false },
            title = { Text("New collection") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM)) {
                    OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { ordered = !ordered },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(checked = ordered, onCheckedChange = { ordered = it })
                        Text("Ordered")
                    }
                }
            },
            confirmButton = { TextButton(onClick = { vm.create(name.trim(), ordered); showCreate = false }) { Text("Create") } },
            dismissButton = { TextButton(onClick = { showCreate = false }) { Text("Cancel") } },
            containerColor = colors.cardBackground,
        )
    }
    renaming?.let { col ->
        var name by remember(col) { mutableStateOf(col.name) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text("Rename collection") },
            text = {
                OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true, modifier = Modifier.fillMaxWidth())
            },
            confirmButton = { TextButton(onClick = { vm.rename(col.id, name.trim()); renaming = null }) { Text("Save") } },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text("Cancel") } },
            containerColor = colors.cardBackground,
        )
    }
    deleting?.let { col ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete collection?") },
            text = { Text("Removes '${col.name}'. The series remain in their libraries.") },
            confirmButton = { TextButton(onClick = { vm.delete(col.id); deleting = null }) { Text("Delete", color = HearthRed) } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
            containerColor = colors.cardBackground,
        )
    }
}
