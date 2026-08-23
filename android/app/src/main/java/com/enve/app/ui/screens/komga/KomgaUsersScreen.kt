package com.enve.app.ui.screens.komga

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.komga.dto.KomgaLibraryDto
import com.enve.komga.dto.KomgaUserDto
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.viewmodel.komga.KomgaUsersViewModel
import com.enve.hearth.design.hearthDisplay

private val HearthRed = Color(0xFFB3453E)

@Composable
fun KomgaUsersScreen(onBack: () -> Unit) {
    val colors = EnveTheme.colors
    val viewModel: KomgaUsersViewModel = hiltViewModel()
    val state by viewModel.state.collectAsState()
    val snackbarHostState = remember { SnackbarHostState() }
    var showCreate by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<KomgaUserDto?>(null) }
    var deleteCandidate by remember { mutableStateOf<KomgaUserDto?>(null) }
    var passwordCandidate by remember { mutableStateOf<KomgaUserDto?>(null) }

    LaunchedEffect(state.toast) {
        state.toast?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.consumeToast()
        }
    }
    LaunchedEffect(state.error) {
        state.error?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.consumeError()
        }
    }

    SettingsScreenLayout(animatedBackground = true) {
        Scaffold(
            containerColor = Color.Transparent,
            snackbarHost = { SnackbarHost(snackbarHostState) },
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
                        "Users",
                        color = colors.primaryText,
                        style = hearthDisplay(22.sp),
                        modifier = Modifier
                            .padding(start = DS.Spacing.MD)
                            .weight(1f),
                    )
                    IconButton(onClick = { showCreate = true }) {
                        Icon(Icons.Default.Add, contentDescription = "Add user", tint = colors.accent)
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
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding)
                        .padding(horizontal = DS.Spacing.LG),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD),
                ) {
                    items(state.users, key = { it.id }) { user ->
                        UserRow(
                            user = user,
                            onEdit = { editing = user },
                            onChangePassword = { passwordCandidate = user },
                            onDelete = { deleteCandidate = user },
                        )
                    }
                    item { Spacer(Modifier.height(80.dp)) }
                }
            }
        }
    }

    if (showCreate) {
        CreateUserDialog(
            onDismiss = { showCreate = false },
            onConfirm = { email, password, isAdmin ->
                viewModel.createUser(email, password, isAdmin)
                showCreate = false
            },
        )
    }
    editing?.let { user ->
        EditUserDialog(
            user = user,
            libraries = state.libraries,
            onDismiss = { editing = null },
            onSaveRoles = { admin, dl, stream ->
                viewModel.updateRoles(user, admin, dl, stream)
                editing = null
            },
            onSaveLibraries = { all, ids ->
                viewModel.updateSharedLibraries(user, all, ids)
                editing = null
            },
        )
    }
    passwordCandidate?.let { user ->
        ChangePasswordDialog(
            user = user,
            onDismiss = { passwordCandidate = null },
            onConfirm = { pw ->
                viewModel.changePassword(user.id, pw)
                passwordCandidate = null
            },
        )
    }
    deleteCandidate?.let { user ->
        AlertDialog(
            onDismissRequest = { deleteCandidate = null },
            title = { Text("Delete user?") },
            text = { Text("Permanently remove ${user.email} from this server?") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteUser(user.id)
                    deleteCandidate = null
                }) { Text("Delete", color = HearthRed) }
            },
            dismissButton = {
                TextButton(onClick = { deleteCandidate = null }) { Text("Cancel") }
            },
            containerColor = colors.cardBackground,
        )
    }
}

@Composable
private fun UserRow(
    user: KomgaUserDto,
    onEdit: () -> Unit,
    onChangePassword: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = EnveTheme.colors
    val isAdmin = user.roles.any { it.equals("ADMIN", ignoreCase = true) }
    SettingsCard {
        Column(modifier = Modifier.padding(DS.Spacing.MD)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .background(colors.accent.copy(alpha = 0.18f), CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Default.Person, contentDescription = null, tint = colors.accent, modifier = Modifier.size(20.dp))
                }
                Column(
                    modifier = Modifier
                        .padding(start = DS.Spacing.MD)
                        .weight(1f),
                ) {
                    Text(user.email, color = colors.primaryText, fontWeight = FontWeight.SemiBold)
                    Text(
                        text = if (isAdmin) "Administrator" else "Standard user",
                        color = if (isAdmin) colors.accent else colors.secondaryText,
                        fontSize = 12.sp,
                    )
                }
                IconButton(onClick = onEdit) {
                    Icon(Icons.Default.Edit, contentDescription = "Edit", tint = colors.accent)
                }
                IconButton(onClick = onDelete) {
                    Icon(Icons.Default.Delete, contentDescription = "Delete", tint = HearthRed)
                }
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = DS.Spacing.SM),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val libraryAccess = if (user.sharedAllLibraries == true) "All libraries" else "${user.sharedLibrariesIds.size} libraries"
                Text(libraryAccess, color = colors.tertiaryText, fontSize = 11.sp)
                TextButton(onClick = onChangePassword) {
                    Text("Change password", color = colors.accent, fontSize = 12.sp)
                }
            }
        }
    }
}

@Composable
private fun CreateUserDialog(
    onDismiss: () -> Unit,
    onConfirm: (String, String, Boolean) -> Unit,
) {
    val colors = EnveTheme.colors
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var isAdmin by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add user") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM)) {
                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text("Email") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text("Password") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { isAdmin = !isAdmin }
                        .padding(vertical = DS.Spacing.XS),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(checked = isAdmin, onCheckedChange = { isAdmin = it })
                    Text("Administrator")
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(email.trim(), password, isAdmin) }) { Text("Create") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        containerColor = colors.cardBackground,
    )
}

@Composable
private fun EditUserDialog(
    user: KomgaUserDto,
    libraries: List<KomgaLibraryDto>,
    onDismiss: () -> Unit,
    onSaveRoles: (Boolean, Boolean, Boolean) -> Unit,
    onSaveLibraries: (Boolean, List<String>) -> Unit,
) {
    val colors = EnveTheme.colors
    var isAdmin by remember(user) { mutableStateOf(user.roles.any { it.equals("ADMIN", true) }) }
    var canDownload by remember(user) { mutableStateOf(user.roles.any { it.equals("FILE_DOWNLOAD", true) }) }
    var canStream by remember(user) { mutableStateOf(user.roles.any { it.equals("PAGE_STREAMING", true) }) }
    var allLibraries by remember(user) { mutableStateOf(user.sharedAllLibraries == true) }
    val selectedLibraries = remember(user) { mutableStateListOf<String>().apply { addAll(user.sharedLibrariesIds) } }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(user.email, fontSize = DS.FontSize.Body) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM)) {
                Text("ROLES", color = colors.tertiaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.6.sp)
                CheckRow("Administrator", isAdmin) { isAdmin = it }
                CheckRow("File download", canDownload) { canDownload = it }
                CheckRow("Page streaming", canStream) { canStream = it }
                TextButton(onClick = { onSaveRoles(isAdmin, canDownload, canStream) }) {
                    Text("Save roles", color = colors.accent)
                }

                HorizontalDivider(color = colors.separator)

                Text("LIBRARY ACCESS", color = colors.tertiaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.6.sp)
                CheckRow("All libraries", allLibraries) { allLibraries = it }
                if (!allLibraries) {
                    libraries.forEach { lib ->
                        CheckRow(
                            label = lib.name,
                            checked = selectedLibraries.contains(lib.id),
                        ) { checked ->
                            if (checked) selectedLibraries.add(lib.id) else selectedLibraries.remove(lib.id)
                        }
                    }
                }
                TextButton(onClick = { onSaveLibraries(allLibraries, selectedLibraries.toList()) }) {
                    Text("Save library access", color = colors.accent)
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        containerColor = colors.cardBackground,
    )
}

@Composable
private fun CheckRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onChange(!checked) }
            .padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked = checked, onCheckedChange = onChange)
        Text(label)
    }
}

@Composable
private fun ChangePasswordDialog(
    user: KomgaUserDto,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    val colors = EnveTheme.colors
    var password by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Change password") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM)) {
                Text("for ${user.email}", color = colors.secondaryText)
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text("New password") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(password) }) { Text("Change") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        containerColor = colors.cardBackground,
    )
}
