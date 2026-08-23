package com.enve.hearth.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Login
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.enve.core.data.model.ProviderConnection
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline

@Composable
internal fun SourceDetailPage(
    connection: ProviderConnection,
    onBack: () -> Unit,
    onSave: (ProviderConnection) -> Unit,
    onEnabled: (Boolean) -> Unit,
    onReauthenticate: () -> Unit,
    onDelete: () -> Unit,
) {
    val palette = Hearth.palette
    var name by remember(connection.id) { mutableStateOf(connection.name) }
    var address by remember(connection.id) { mutableStateOf(connection.serverUrl) }
    var username by remember(connection.id) { mutableStateOf(connection.username) }
    var enabled by remember(connection.id) { mutableStateOf(connection.enabled) }
    var showDeleteConfirmation by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(palette.bg)) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.AutoMirrored.Outlined.ArrowBack,
                "Back",
                tint = palette.text,
                modifier = Modifier.clip(CircleShape).clickable(onClick = onBack).padding(Hearth.Spacing.S).size(26.dp),
            )
            Spacer(Modifier.size(Hearth.Spacing.S))
            Column {
                Overline("Connected source")
                Text(name.ifBlank { connection.source.name }, style = HearthText.ScreenTitle, color = palette.text)
            }
        }

        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Hearth.Spacing.XL)
                .padding(bottom = LocalMantelInset.current + Hearth.Spacing.XL),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
        ) {
            SourceCard {
                Overline("Connection")
                SourceField("Name", name, { name = it })
                SourceField("Address", address, { address = it }, KeyboardType.Uri)
                SourceField("Username", username, { username = it })
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Enabled", style = HearthText.Label, color = palette.text)
                        Text("Include this source in library refreshes", style = HearthText.Caption, color = palette.textSecondary)
                    }
                    Switch(
                        checked = enabled,
                        onCheckedChange = {
                            enabled = it
                            onEnabled(it)
                        },
                        colors = SwitchDefaults.colors(
                            checkedTrackColor = palette.ember,
                            checkedThumbColor = palette.readableOnEmber,
                        ),
                    )
                }
                EmberButton("Save changes", onClick = {
                    onSave(connection.copy(name = name.trim(), serverUrl = address.trim(), username = username.trim(), enabled = enabled))
                })
            }

            SourceCard {
                Overline("Authentication")
                Text(
                    if (connection.needsReauth) "This source needs you to sign in again." else "Credentials are stored securely on this device.",
                    style = HearthText.Body,
                    color = if (connection.needsReauth) palette.statusWarn else palette.textSecondary,
                )
                OutlinedButton(onClick = onReauthenticate, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.AutoMirrored.Outlined.Login, null)
                    Spacer(Modifier.size(Hearth.Spacing.S))
                    Text("Sign in again")
                }
            }

            SourceCard {
                Overline("Danger zone")
                Text(
                    "Removing this source deletes its saved credentials and cached library index. Downloaded files remain on this device.",
                    style = HearthText.Body,
                    color = palette.textSecondary,
                )
                OutlinedButton(
                    onClick = { showDeleteConfirmation = true },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.statusError),
                ) {
                    Icon(Icons.Outlined.Delete, null)
                    Spacer(Modifier.size(Hearth.Spacing.S))
                    Text("Remove source")
                }
            }
        }
    }

    if (showDeleteConfirmation) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirmation = false },
            title = { Text("Remove ${connection.name.ifBlank { connection.source.name }}?") },
            text = { Text("This removes the connection, sign-in credentials, and cached library entries. Downloaded books will not be deleted.") },
            confirmButton = {
                TextButton(onClick = {
                    showDeleteConfirmation = false
                    onDelete()
                }) { Text("Remove", color = palette.statusError) }
            },
            dismissButton = { TextButton(onClick = { showDeleteConfirmation = false }) { Text("Cancel") } },
            containerColor = palette.bgElevated,
            titleContentColor = palette.text,
            textContentColor = palette.textSecondary,
        )
    }
}

@Composable
private fun SourceCard(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxWidth().background(Hearth.palette.bgElevated, RoundedCornerShape(Hearth.Radius.Card))
            .padding(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        content = content,
    )
}

@Composable
private fun SourceField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    keyboardType: KeyboardType = KeyboardType.Text,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
    )
}
