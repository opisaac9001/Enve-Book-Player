package com.enve.hearth.profiles

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.local.AdultPinResult
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.FamilyProfile
import com.enve.core.data.local.FamilyProfileRole
import com.enve.engine.profiles.ProfileDownloadCandidate
import com.enve.engine.profiles.ProfileDownloadFormat
import com.enve.engine.profiles.ProfilesFacade
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

private sealed interface ProfileDialog {
    data object Enable : ProfileDialog
    data object Add : ProfileDialog
    data object Unlock : ProfileDialog
    data object Pin : ProfileDialog
    data class Rename(val profile: FamilyProfile) : ProfileDialog
    data class Remove(val profile: FamilyProfile) : ProfileDialog
}

@Composable
fun HearthProfilesScreen(facade: ProfilesFacade, onBack: () -> Unit) {
    val state by facade.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var dialog by remember { mutableStateOf<ProfileDialog?>(null) }
    var importTarget by remember { mutableStateOf<FamilyProfile?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val run: (suspend () -> Unit) -> Unit = { action ->
        scope.launch {
            busy = true
            error = null
            try {
                action()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                error = "That change could not be saved. Check the details and try again."
            } finally {
                busy = false
            }
        }
    }
    importTarget?.let { target ->
        HearthProfileImportScreen(facade, target) { importTarget = null }
        return
    }
    val requiresUnlock = state.profiles.any { it.role == FamilyProfileRole.CHILD } && !state.parentAuthorized
    ProfilePage("Profiles", "Separate libraries, settings and reading positions on this device.", onBack) {
        if (!state.enabled) {
            Text("Your current library becomes the first adult profile. Books already on this device stay available.", color = Hearth.palette.textSecondary)
            EmberButton("Set up profiles", { dialog = ProfileDialog.Enable }, Modifier.testTag("profiles-enable"))
        } else {
            state.profiles.forEach { profile ->
                Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    Text(profile.name, style = HearthText.BookTitle, color = Hearth.palette.text)
                    Text(
                        "${if (profile.role == FamilyProfileRole.CHILD) "Child" else "Adult"}${if (profile.id == state.activeProfileId) " · Current profile" else ""}",
                        color = Hearth.palette.textSecondary,
                    )
                    QuietButton("Use ${profile.name}", {
                        if (profile.role == FamilyProfileRole.ADULT && requiresUnlock) dialog = ProfileDialog.Unlock
                        else run { facade.switchProfile(profile.id) }
                    }, Modifier.testTag("profile-switch-${profile.id}"))
                    if (!requiresUnlock) {
                        ProfileSyncChoice(
                            enabled = state.serverSyncEnabled[profile.id] ?: (profile.id == DEFAULT_ADULT_PROFILE_ID),
                            onChanged = { enabled -> run { facade.setServerSyncEnabled(profile.id, enabled) } },
                            busy = busy,
                            testTag = "profile-server-sync-${profile.id}",
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(onClick = { dialog = ProfileDialog.Rename(profile) }) { Text("Rename") }
                            if (profile.id != DEFAULT_ADULT_PROFILE_ID && profile.id != state.activeProfileId) {
                                TextButton(onClick = { dialog = ProfileDialog.Remove(profile) }) { Text("Remove") }
                            }
                        }
                        QuietButton("Import downloaded books", { importTarget = profile })
                    }
                    HorizontalDivider(color = Hearth.palette.hairline)
                }
            }
            if (requiresUnlock) {
                EmberButton("Adult controls", { dialog = ProfileDialog.Unlock }, Modifier.testTag("profiles-unlock"))
            } else {
                EmberButton("Add profile", { dialog = ProfileDialog.Add }, Modifier.testTag("profiles-add"))
                QuietButton("Set or change adult PIN", { dialog = ProfileDialog.Pin })
                if (state.profiles.size == 1) QuietButton("Turn off profiles", { run { facade.disableProfiles() } })
            }
        }
        if (busy || state.switching) CircularProgressIndicator(color = Hearth.palette.ember)
        (error ?: state.error)?.let { Text(it, color = Hearth.palette.statusError) }
    }
    dialog?.let { current ->
        ProfileEditorDialog(current, facade, busy, error, onDismiss = { dialog = null; error = null }) { name, role, pin, confirmation, oldPin, syncEnabled ->
            run {
                when (current) {
                    ProfileDialog.Enable -> facade.setupOwner(name, pin.ifBlank { null }, confirmation.ifBlank { null }, serverSyncEnabled = syncEnabled)
                    ProfileDialog.Add -> {
                        if (role == FamilyProfileRole.CHILD && pin.isNotBlank()) {
                            facade.changeAdultPin(oldPin.ifBlank { null }, pin, confirmation)
                        }
                        facade.addProfile(name, role, serverSyncEnabled = syncEnabled)
                    }
                    ProfileDialog.Unlock -> when (facade.verifyAdultPin(pin)) {
                        AdultPinResult.Accepted -> Unit
                        AdultPinResult.Rejected -> error("Incorrect PIN")
                        is AdultPinResult.Locked -> error("PIN locked")
                    }
                    ProfileDialog.Pin -> facade.changeAdultPin(oldPin.ifBlank { null }, pin, confirmation)
                    is ProfileDialog.Rename -> facade.renameProfile(current.profile.id, name)
                    is ProfileDialog.Remove -> facade.removeProfile(current.profile.id)
                }
                dialog = null
            }
        }
    }
}

@Composable
fun HearthProfilePickerScreen(facade: ProfilesFacade, onSelected: () -> Unit) {
    val state by facade.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var pin by remember { mutableStateOf("") }
    var adult by remember { mutableStateOf<FamilyProfile?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val choose: (FamilyProfile, String?) -> Unit = { profile, suppliedPin ->
        scope.launch {
            try {
                facade.switchProfile(profile.id, suppliedPin)
                adult = null
                pin = ""
                onSelected()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                error = "Unable to open this profile. Check your PIN and try again."
            }
        }
    }
    ProfilePage("Who's reading?", "Choose a profile to continue.") {
        state.profiles.forEach { profile ->
            QuietButton(profile.name, {
                if (profile.role == FamilyProfileRole.ADULT && state.profiles.any { it.role == FamilyProfileRole.CHILD } && !state.parentAuthorized) adult = profile
                else choose(profile, null)
            }, Modifier.fillMaxWidth().testTag("profile-picker-${profile.id}"))
        }
        if (state.switching) CircularProgressIndicator(color = Hearth.palette.ember)
        error?.let { Text(it, color = Hearth.palette.statusError) }
    }
    adult?.let { profile ->
        AlertDialog(
            onDismissRequest = { adult = null; pin = "" },
            title = { Text("Open ${profile.name}") },
            text = { ProfilePinField("Adult PIN", pin) { pin = it } },
            confirmButton = { TextButton(onClick = { choose(profile, pin) }, enabled = !state.switching) { Text("Unlock") } },
            dismissButton = { TextButton(onClick = { adult = null; pin = "" }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun ProfileSyncChoice(enabled: Boolean, onChanged: (Boolean) -> Unit, busy: Boolean, testTag: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Do you want to turn on syncing?", color = Hearth.palette.text)
        Text(
            "On continues reading and listening across devices using this server account. Off keeps progress separate when sharing a login with someone else.",
            color = Hearth.palette.textSecondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Switch(
                checked = enabled,
                onCheckedChange = onChanged,
                enabled = !busy,
                colors = SwitchDefaults.colors(checkedTrackColor = Hearth.palette.ember),
                modifier = Modifier.testTag(testTag),
            )
            Text(if (enabled) "On" else "Off", color = Hearth.palette.text)
        }
    }
}

@Composable
private fun ProfileEditorDialog(
    dialog: ProfileDialog,
    facade: ProfilesFacade,
    busy: Boolean,
    error: String?,
    onDismiss: () -> Unit,
    onSave: (String, FamilyProfileRole, String, String, String, Boolean) -> Unit,
) {
    var name by remember(dialog) { mutableStateOf(if (dialog is ProfileDialog.Rename) dialog.profile.name else "") }
    var syncEnabled by remember(dialog) {
        mutableStateOf(if (dialog == ProfileDialog.Enable) facade.state.value.serverSyncEnabled[DEFAULT_ADULT_PROFILE_ID] ?: true else false)
    }
    var role by remember(dialog) { mutableStateOf(FamilyProfileRole.ADULT) }
    var pin by remember(dialog) { mutableStateOf("") }
    var confirmation by remember(dialog) { mutableStateOf("") }
    var oldPin by remember(dialog) { mutableStateOf("") }
    var recoveryAuthenticated by remember { mutableStateOf(false) }
    val recovery = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        recoveryAuthenticated = result.resultCode == android.app.Activity.RESULT_OK
    }
    val scope = rememberCoroutineScope()
    var recoveryError by remember { mutableStateOf<String?>(null) }
    val title = when (dialog) {
        ProfileDialog.Enable -> "Set up profiles"
        ProfileDialog.Add -> "Add profile"
        ProfileDialog.Unlock -> "Adult controls"
        ProfileDialog.Pin -> "Adult PIN"
        is ProfileDialog.Rename -> "Rename profile"
        is ProfileDialog.Remove -> "Remove ${dialog.profile.name}?"
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                error?.let { Text(it, color = Hearth.palette.statusError) }
                if (dialog is ProfileDialog.Remove) {
                    Text("This removes this person's library and positions from this device. Books used by other profiles stay available.")
                } else if (dialog != ProfileDialog.Unlock && dialog != ProfileDialog.Pin) {
                    OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.testTag("profile-name"))
                }
                if (dialog == ProfileDialog.Add || dialog == ProfileDialog.Enable) {
                    ProfileSyncChoice(syncEnabled, { syncEnabled = it }, busy, "profile-setup-server-sync")
                }
                if (dialog == ProfileDialog.Add) {
                    Row {
                        TextButton(onClick = { role = FamilyProfileRole.ADULT }) { Text(if (role == FamilyProfileRole.ADULT) "✓ Adult" else "Adult") }
                        TextButton(onClick = { role = FamilyProfileRole.CHILD }) { Text(if (role == FamilyProfileRole.CHILD) "✓ Child" else "Child") }
                    }
                    if (role == FamilyProfileRole.CHILD) Text("Child profiles need an adult PIN. Set one below if you haven't already.")
                }
                if (dialog == ProfileDialog.Pin && !recoveryAuthenticated) ProfilePinField("Current PIN, if set", oldPin) { oldPin = it }
                if (dialog == ProfileDialog.Enable || dialog == ProfileDialog.Unlock || dialog == ProfileDialog.Pin || (dialog == ProfileDialog.Add && role == FamilyProfileRole.CHILD)) {
                    ProfilePinField(if (dialog == ProfileDialog.Unlock) "Adult PIN" else "New PIN", pin) { pin = it }
                    if (dialog != ProfileDialog.Unlock) ProfilePinField("Confirm PIN", confirmation) { confirmation = it }
                }
                if (dialog == ProfileDialog.Pin) {
                    facade.pinRecoveryIntent()?.let { intent ->
                        TextButton(onClick = { recovery.launch(intent) }) { Text("Forgot PIN? Verify this device") }
                    }
                    recoveryError?.let { Text(it, color = Hearth.palette.statusError) }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                if (dialog == ProfileDialog.Pin && recoveryAuthenticated) {
                    scope.launch {
                        try {
                            facade.resetAdultPinAfterDeviceAuthentication(pin, confirmation)
                            onDismiss()
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (_: Exception) {
                            recoveryError = "PIN reset failed. Verify the device and try again."
                        }
                    }
                } else onSave(name, role, pin, confirmation, oldPin, syncEnabled)
            }, enabled = !busy) { Text(if (dialog is ProfileDialog.Remove) "Remove" else if (dialog == ProfileDialog.Unlock) "Unlock" else "Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun ProfilePinField(label: String, value: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value, onChange, label = { Text(label) }, singleLine = true,
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
        modifier = Modifier.testTag("profile-pin-$label"),
    )
}

@Composable
internal fun ProfilePage(title: String, subtitle: String, onBack: (() -> Unit)? = null, content: @Composable () -> Unit) {
    BackHandler(enabled = onBack != null) { onBack?.invoke() }
    Column(
        Modifier.fillMaxSize().background(Hearth.palette.bg).statusBarsPadding()
            .verticalScroll(rememberScrollState()).padding(horizontal = 24.dp)
            .padding(top = 12.dp, bottom = LocalMantelInset.current + 24.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        onBack?.let { TextButton(onClick = it) { Text("Back") } }
        Overline("On this device")
        Text(title, style = HearthText.ScreenTitle, color = Hearth.palette.text)
        Text(subtitle, style = HearthText.Body, color = Hearth.palette.textSecondary)
        content()
    }
}

@Composable
private fun HearthProfileImportScreen(facade: ProfilesFacade, target: FamilyProfile, onBack: () -> Unit) {
    val state by facade.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var source by remember { mutableStateOf<FamilyProfile?>(null) }
    var candidates by remember { mutableStateOf<List<ProfileDownloadCandidate>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val permitted = state.parentAuthorized || state.profiles.none { it.role == FamilyProfileRole.CHILD }
    LaunchedEffect(permitted) {
        if (!permitted) { candidates = emptyList(); source = null }
    }
    ProfilePage("Import downloaded books", "For ${target.name}. Files are reused; reading and listening start with a separate position.", onBack) {
        if (!permitted) {
            Text("Unlock adult controls to choose books from another profile.", color = Hearth.palette.textSecondary)
        } else {
            state.profiles.filter { it.id != target.id }.forEach { profile ->
                QuietButton("Choose from ${profile.name}", {
                    source = profile
                    candidates = emptyList()
                    scope.launch {
                        busy = true
                        try {
                            val loaded = facade.importCandidates(profile.id)
                            if ((facade.state.value.parentAuthorized || facade.state.value.profiles.none { it.role == FamilyProfileRole.CHILD }) && source?.id == profile.id) candidates = loaded
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (_: Exception) {
                            message = "Couldn't load completed downloads. Try again."
                        } finally { busy = false }
                    }
                })
            }
            if (source != null && candidates.isEmpty() && !busy) Text("No completed downloads are available from this profile.", color = Hearth.palette.textSecondary)
            candidates.forEach { candidate ->
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(candidate.title, style = HearthText.BookTitle, color = Hearth.palette.text)
                    candidate.author?.let { Text(it, color = Hearth.palette.textSecondary) }
                    Text(if (candidate.format == ProfileDownloadFormat.AUDIOBOOK) "Audiobook" else "Ebook", color = Hearth.palette.textSecondary)
                    QuietButton("Import", {
                        if (!busy) scope.launch {
                            busy = true
                            try {
                                facade.importCompleted(candidate.sourceProfileId, target.id, candidate.bookKey, candidate.format)
                                message = "Added to ${target.name}'s library."
                            } catch (cancelled: CancellationException) {
                                throw cancelled
                            } catch (_: Exception) {
                                message = "Couldn't import this download. The original book is unchanged."
                            } finally { busy = false }
                        }
                    })
                }
            }
        }
        if (busy) CircularProgressIndicator(color = Hearth.palette.ember)
        message?.let { Text(it, color = Hearth.palette.textSecondary) }
    }
}
