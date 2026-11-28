package com.enve.hearth.settings

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.SecureFlagPolicy
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.enve.engine.backup.SettingsCodeOffer
import com.enve.engine.backup.SettingsTransferFacade
import com.enve.engine.backup.SettingsTransferOffer
import com.enve.engine.backup.SettingsTransferReview
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.listeningposition.ListeningPositionCameraScanner
import com.enve.hearth.listeningposition.ListeningPositionQRCode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

private enum class TransferDialog { SEND, WARNING, SCAN, CODE, EXPORT, UNLOCK }

@Composable
internal fun SettingsDeviceTransfer(transfer: SettingsTransferFacade, importOnly: Boolean) {
    val palette = Hearth.palette
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var dialog by remember { mutableStateOf<TransferDialog?>(null) }
    var offer by remember { mutableStateOf<SettingsTransferOffer?>(null) }
    var review by remember { mutableStateOf<SettingsTransferReview?>(null) }
    var incomingFile by remember { mutableStateOf<Uri?>(null) }
    var includeSettings by remember { mutableStateOf(true) }
    var includeSources by remember { mutableStateOf(true) }
    var includeIntegrations by remember { mutableStateOf(true) }
    var includeSignIns by remember { mutableStateOf(false) }
    var passphrase by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    var retryScan by remember { mutableStateOf(false) }
    var useTypedCode by remember { mutableStateOf(false) }
    var enteredCode by remember { mutableStateOf("") }
    var receivingByCode by remember { mutableStateOf<Job?>(null) }

    fun run(errorMessage: String, action: suspend () -> Unit): Job? {
        if (busy) return null
        busy = true
        notice = null
        return scope.launch {
            try { action() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { notice = errorMessage }
            finally {
                busy = false
                receivingByCode = null
            }
        }
    }

    fun send(includeCredentials: Boolean) {
        dialog = null
        run("Couldn't start the transfer. Connect both devices to the same Wi-Fi and try again.") {
            offer = if (useTypedCode) {
                transfer.sendCode(includeSettings, includeSources, includeIntegrations, includeCredentials)
            } else {
                transfer.send(includeSettings, includeSources, includeIntegrations, includeCredentials)
            }
        }
    }

    fun chooseTransfer(typedCode: Boolean) {
        useTypedCode = typedCode
        if ((includeSources || includeIntegrations) && includeSignIns) dialog = TransferDialog.WARNING
        else send(false)
    }

    fun scan(code: String) {
        if (dialog != TransferDialog.SCAN || !code.startsWith("enve-settings:") || busy) return
        dialog = null
        retryScan = false
        run("Couldn't connect. Check Wi-Fi and scan a fresh Enve transfer code.") {
            review = transfer.receive(code)
        }
    }

    val imagePicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null && dialog == TransferDialog.SCAN) {
            scope.launch {
                try {
                    val code = ListeningPositionQRCode.messages(context, uri).firstOrNull { it.startsWith("enve-settings:") }
                    if (code != null) scan(code) else retryScan = true
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { retryScan = true }
            }
        }
    }
    val saveFile = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        val entered = passphrase
        passphrase = ""
        confirmation = ""
        if (uri != null) run("Couldn't save the encrypted backup.") {
            transfer.exportFile(uri.toString(), includeSettings, includeSources, includeIntegrations, includeSignIns, entered)
            notice = "Encrypted backup saved."
        }
    }
    val chooseFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            incomingFile = uri
            passphrase = ""
            dialog = TransferDialog.UNLOCK
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        Overline(if (importOnly) "Import settings and sources" else "Transfer between devices")
        Text(
            if (importOnly) "Scan a QR code, enter a six-digit code, or choose an encrypted backup file."
            else "Move settings between iPhone and Android over the same Wi-Fi network.",
            color = palette.textSecondary,
            style = HearthText.Body,
        )
        if (!importOnly) {
            EmberButton("Transfer to another device", onClick = {
                if (!busy) {
                    includeSignIns = false
                    dialog = TransferDialog.SEND
                }
            })
        }
        QuietButton("Scan to import", onClick = { if (!busy) { retryScan = false; dialog = TransferDialog.SCAN } })
        QuietButton("Enter a code", onClick = {
            if (!busy) {
                enteredCode = ""
                dialog = TransferDialog.CODE
            }
        })
        if (!importOnly) {
            QuietButton("Create encrypted backup", onClick = {
                if (!busy) {
                    includeSignIns = false
                    passphrase = ""
                    confirmation = ""
                    dialog = TransferDialog.EXPORT
                }
            })
        }
        QuietButton("Import encrypted backup", onClick = {
            if (!busy) chooseFile.launch(arrayOf("application/json", "application/octet-stream", "text/plain"))
        })
        if (busy) {
            Text(
                if (receivingByCode == null) "Working…" else "Approve the transfer on your other device when asked.",
                style = HearthText.Caption, color = palette.textSecondary,
            )
            receivingByCode?.let { job -> QuietButton("Cancel transfer", onClick = { job.cancel() }) }
        }
        notice?.let { Text(it, style = HearthText.Caption, color = palette.textSecondary) }
    }

    when (dialog) {
        TransferDialog.SEND, TransferDialog.EXPORT -> {
            val isFile = dialog == TransferDialog.EXPORT
            AlertDialog(
                onDismissRequest = { dialog = null },
                title = { Text(if (isFile) "Encrypted backup" else "Transfer to another device") },
                text = {
                    Column(Modifier.verticalScroll(rememberScrollState())) {
                        TransferCheckbox("Settings", includeSettings) { includeSettings = it }
                        TransferCheckbox("Library sources", includeSources) { includeSources = it }
                        TransferCheckbox("Reading integrations", includeIntegrations) { includeIntegrations = it }
                        if (includeSources || includeIntegrations) TransferCheckbox("Include supported sign-ins", includeSignIns) { includeSignIns = it }
                        if (isFile) {
                            TransferPassphrase(passphrase) { passphrase = it }
                            TransferPassphrase(confirmation, "Confirm passphrase") { confirmation = it }
                        }
                    }
                },
                confirmButton = {
                    val hasSelection = includeSettings || includeSources || includeIntegrations
                    if (isFile) {
                        TextButton(
                            enabled = hasSelection && passphrase.length >= 12 && passphrase == confirmation,
                            onClick = {
                                dialog = null
                                saveFile.launch("Enve Backup.json")
                            },
                        ) { Text("Save backup") }
                    } else {
                        Column(horizontalAlignment = Alignment.End) {
                            TextButton(enabled = hasSelection, onClick = { chooseTransfer(false) }) { Text("Show QR code") }
                            TextButton(enabled = hasSelection, onClick = { chooseTransfer(true) }) { Text("Show six-digit code") }
                        }
                    }
                },
                dismissButton = { TextButton(onClick = { dialog = null }) { Text("Cancel") } },
            )
        }
        TransferDialog.WARNING -> AlertDialog(
            onDismissRequest = { dialog = null },
            title = { Text("Share your saved sign-ins?") },
            text = {
                Text("This can copy saved passwords and API keys. The other device may be able to access your accounts and libraries. Only continue if you own and control both devices. Don’t show this code to anyone else, send a screenshot, or continue because someone asked you to share it.")
            },
            confirmButton = {
                Column(horizontalAlignment = Alignment.End) {
                    TextButton(onClick = { send(false) }) { Text("Transfer without sign-ins") }
                    TextButton(onClick = { send(true) }) { Text(if (useTypedCode) "Show code with sign-ins" else "Show QR code with sign-ins", color = palette.statusError) }
                }
            },
            dismissButton = { TextButton(onClick = { dialog = null }) { Text("Cancel") } },
        )
        TransferDialog.SCAN -> AlertDialog(
            onDismissRequest = { dialog = null },
            title = { Text("Scan a transfer code") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    ListeningPositionCameraScanner(::scan)
                    if (retryScan) Text("That image doesn’t contain an Enve transfer code.")
                    QuietButton("Choose QR image", onClick = { imagePicker.launch("image/*") })
                }
            },
            confirmButton = { TextButton(onClick = { dialog = null }) { Text("Cancel") } },
        )
        TransferDialog.CODE -> AlertDialog(
            onDismissRequest = { dialog = null },
            title = { Text("Enter a code") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    Text("Enter the six-digit code from the other device on the same Wi-Fi.")
                    OutlinedTextField(
                        value = enteredCode,
                        onValueChange = { enteredCode = it.filter { digit -> digit in '0'..'9' }.take(6) },
                        label = { Text("Transfer code") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        singleLine = true,
                    )
                }
            },
            confirmButton = {
                TextButton(enabled = enteredCode.length == 6, onClick = {
                    val code = enteredCode
                    enteredCode = ""
                    dialog = null
                    receivingByCode = run("Couldn't pair. Make sure both devices are on the same Wi-Fi and use a fresh code.") {
                        review = transfer.receiveCode(code)
                    }
                }) { Text("Connect") }
            },
            dismissButton = { TextButton(onClick = { dialog = null }) { Text("Cancel") } },
        )
        TransferDialog.UNLOCK -> AlertDialog(
            onDismissRequest = { dialog = null },
            title = { Text("Unlock encrypted backup") },
            text = { TransferPassphrase(passphrase) { passphrase = it } },
            confirmButton = {
                TextButton(enabled = passphrase.isNotEmpty(), onClick = {
                    val uri = incomingFile ?: return@TextButton
                    val entered = passphrase
                    passphrase = ""
                    dialog = null
                    run("Couldn't unlock the backup. Check the passphrase and try again.") {
                        review = transfer.importFile(uri.toString(), entered)
                    }
                }) { Text("Unlock") }
            },
            dismissButton = { TextButton(onClick = { dialog = null }) { Text("Cancel") } },
        )
        null -> Unit
    }

    offer?.let { active ->
        OfferDialog(
            active,
            onClose = { offer = null },
            onSent = { offer = null; notice = "Backup sent. Review it on the other device." },
            onError = { offer = null; notice = "Transfer ended. Start again for a new code." },
        )
    }

    review?.let { incoming ->
        ReviewDialog(incoming, applying = busy, onDismiss = { if (!busy) review = null }) { settings, ids, integrations ->
            run("Couldn't finish restoring the backup. Reopen it to review the remaining changes.") {
                val result = incoming.restore(settings, ids, integrations)
                review = null
                notice = buildString {
                    append(if (result.settingsSaved) "Restore complete." else "Some settings couldn’t be saved.")
                    if (result.restoredSources > 0) append(" Imported ${result.restoredSources} sources.")
                    if (result.keptSources > 0) append(" Kept ${result.keptSources} existing sources.")
                    if (result.integrationsRestored > 0) append(" Imported ${result.integrationsRestored} integrations.")
                    if (result.integrationsToReconnect.isNotEmpty()) append(" Sign in again for ${result.integrationsToReconnect.joinToString()}.")
                    if (result.signInsNeeded > 0) append(" Sign in again for ${result.signInsNeeded} sources.")
                }
            }
        }
    }
}

@Composable
private fun OfferDialog(
    offer: SettingsTransferOffer,
    onClose: () -> Unit,
    onSent: () -> Unit,
    onError: () -> Unit,
) {
    val owner = LocalLifecycleOwner.current
    DisposableEffect(offer, owner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) onClose() }
        owner.lifecycle.addObserver(observer)
        onDispose {
            owner.lifecycle.removeObserver(observer)
            offer.close()
        }
    }
    LaunchedEffect(offer) {
        try { offer.awaitTransfer(); onSent() }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { onError() }
    }
    val codeOffer = offer as? SettingsCodeOffer
    val awaitingApproval = codeOffer?.awaitingApproval?.collectAsState()?.value == true
    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(if (codeOffer == null) "Scan with your other device" else "Pair with your other device") },
        properties = DialogProperties(securePolicy = SecureFlagPolicy.SecureOn),
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                when {
                    awaitingApproval -> Text("Send this backup to your other device?")
                    codeOffer != null -> {
                        Text(offer.code, style = HearthText.ScreenTitle)
                        Text("On your other device, choose Enter a code. This code expires in 90 seconds.")
                    }
                    else -> {
                        val image = remember(offer) { ListeningPositionQRCode.image(offer.code).asImageBitmap() }
                        Image(image, "One-time transfer QR code", Modifier.size(224.dp))
                        Text("Use Scan to import in Enve on the same Wi-Fi. This code expires in 90 seconds.")
                    }
                }
            }
        },
        confirmButton = {
            if (awaitingApproval) {
                TextButton(onClick = codeOffer::approve) { Text("Approve transfer") }
            }
        },
        dismissButton = { TextButton(onClick = onClose) { Text("Cancel transfer") } },
    )
}

@Composable
private fun ReviewDialog(
    review: SettingsTransferReview,
    applying: Boolean,
    onDismiss: () -> Unit,
    onRestore: (Boolean, Set<String>, Set<String>) -> Unit,
) {
    var copySettings by remember(review) { mutableStateOf(review.preview.changes.isNotEmpty()) }
    var sources by remember(review) { mutableStateOf(review.preview.sources.map { it.id }.toSet()) }
    var integrations by remember(review) { mutableStateOf(review.preview.integrations.map { it.id }.toSet()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Review backup") },
        text = {
            Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                if (review.preview.changes.isNotEmpty()) {
                    TransferCheckbox("Restore settings", copySettings) { copySettings = it }
                    review.preview.changes.forEach { Text("${it.label} · ${it.incoming}", style = HearthText.Caption) }
                }
                review.preview.sources.forEach { source ->
                    TransferCheckbox(source.name, source.id in sources) {
                        sources = if (it) sources + source.id else sources - source.id
                    }
                    Text(source.address + if (source.needsSignIn) " · Sign in again" else "", style = HearthText.Caption)
                }
                review.preview.integrations.forEach { integration ->
                    TransferCheckbox(integration.name, integration.id in integrations) {
                        integrations = if (it) integrations + integration.id else integrations - integration.id
                    }
                    if (integration.needsSignIn) Text("Sign in again after import.", style = HearthText.Caption)
                }
                if (review.preview.sources.isEmpty() && review.preview.changes.isEmpty() && review.preview.integrations.isEmpty()) Text("There are no settings or sources to change on this device.")
            }
        },
        confirmButton = {
            TextButton(enabled = !applying && (copySettings || sources.isNotEmpty() || integrations.isNotEmpty()), onClick = { onRestore(copySettings, sources, integrations) }) {
                Text("Restore selected items")
            }
        },
        dismissButton = { TextButton(enabled = !applying, onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun TransferPassphrase(value: String, label: String = "Backup passphrase", onChange: (String) -> Unit) {
    OutlinedTextField(value, onChange, label = { Text(label) }, singleLine = true, visualTransformation = PasswordVisualTransformation())
}

@Composable
private fun TransferCheckbox(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().toggleable(checked, onValueChange = onChange), verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked, onCheckedChange = null)
        Text(label)
    }
}
