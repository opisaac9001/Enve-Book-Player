package com.enve.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.enve.app.ui.theme.EnveTheme
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

internal fun calibreCatalogUrl(value: String): String? {
    val url = value.trim().toHttpUrlOrNull() ?: return null
    if (url.username.isNotEmpty() || url.password.isNotEmpty()) return null
    return url.newBuilder().apply {
        if (url.pathSegments.lastOrNull { it.isNotEmpty() } != "opds") {
            encodedPath(url.encodedPath.trimEnd('/') + "/opds")
        }
        fragment(null)
    }.build().toString()
}

@Composable
internal fun CalibreConnectionDialog(onDismiss: () -> Unit, onConnect: (String) -> Unit) {
    var address by rememberSaveable { mutableStateOf("") }
    val catalog = calibreCatalogUrl(address)
    val colors = EnveTheme.colors
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colors.background,
        titleContentColor = colors.primaryText,
        textContentColor = colors.secondaryText,
        title = { Text("Connect Calibre") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("In Calibre, choose Connect/share → Start Content server. Enter its address below. For Calibre-Web, use its server address.")
                OutlinedTextField(
                    value = address,
                    onValueChange = { address = it },
                    singleLine = true,
                    label = { Text("Server address") },
                    placeholder = { Text("http://192.168.1.5:8080") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    isError = address.isNotBlank() && catalog == null,
                    supportingText = { Text("Use an http:// or https:// address. Enter credentials on the next screen.") },
                )
                Text("Enve uses the OPDS catalog to browse and download books. Calibre reading progress and library edits are not synced.")
            }
        },
        confirmButton = {
            TextButton(enabled = catalog != null, onClick = { catalog?.let(onConnect) }) { Text("Continue") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
