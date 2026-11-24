package com.enve.hearth.readwise

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.engine.readwise.ReadwiseExportPreview
import com.enve.engine.readwise.ReadwiseExportProgress
import com.enve.engine.readwise.ReadwiseExportResult
import com.enve.engine.readwise.ReadwiseExportScope
import com.enve.engine.readwise.ReadwiseFailure
import com.enve.engine.readwise.ReadwisePreviewHighlight
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.shell.profileViewModel

@Composable
fun HearthReadwiseScreen(
    scope: ReadwiseExportScope,
    onBack: () -> Unit,
    vm: ReadwiseViewModel = profileViewModel(),
) {
    val palette = Hearth.palette
    val state by vm.state.collectAsStateWithLifecycle()
    val connected by vm.isConnected.collectAsStateWithLifecycle()

    LaunchedEffect(scope) { vm.setScope(scope) }

    if (state.confirmingExport) {
        state.preview?.let { preview ->
            ConfirmExportDialog(preview, onConfirm = vm::confirmExport, onDismiss = vm::dismissExport)
        }
    }

    Column(Modifier.fillMaxSize().background(palette.bg)) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.AutoMirrored.Outlined.ArrowBack, "Back", tint = palette.text,
                modifier = Modifier.clip(CircleShape).clickable(onClick = onBack)
                    .padding(Hearth.Spacing.S).size(26.dp),
            )
            Spacer(Modifier.size(Hearth.Spacing.S))
            Column {
                Overline(if (scope is ReadwiseExportScope.Book) "This book's highlights" else "All highlights")
                Text("Readwise", style = HearthText.ScreenTitle, color = palette.text, modifier = Modifier.semantics { heading() })
            }
        }

        LazyColumn(
            contentPadding = PaddingValues(
                start = Hearth.Spacing.XL, end = Hearth.Spacing.XL,
                top = Hearth.Spacing.S, bottom = LocalMantelInset.current + Hearth.Spacing.XL,
            ),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXL),
        ) {
            item {
                AccountCard(
                    connected = connected,
                    state = state,
                    onTokenChange = vm::updateToken,
                    onConnect = vm::connect,
                    onValidate = vm::validate,
                    onDisconnect = vm::disconnect,
                )
            }
            item {
                ExportCard(
                    connected = connected,
                    state = state,
                    onSend = vm::requestExport,
                    onCancel = vm::cancelExport,
                    onDismissResult = vm::dismissResult,
                )
            }
            item {
                Text(
                    "Exports only run when you send them. Enve sends highlighted text, notes, book titles and authors, and page or time positions when it has them. Bookmarks and notes without highlighted text stay on this device. Edited highlights become ready to send again.",
                    style = HearthText.Caption,
                    color = palette.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun AccountCard(
    connected: Boolean,
    state: ReadwiseUiState,
    onTokenChange: (String) -> Unit,
    onConnect: () -> Unit,
    onValidate: () -> Unit,
    onDisconnect: () -> Unit,
) {
    val palette = Hearth.palette
    val uriHandler = LocalUriHandler.current
    Card {
        Overline("Account")
        Spacer(Modifier.size(Hearth.Spacing.M))
        if (connected) {
            Text(
                when (state.accountCheck) {
                    ReadwiseAccountCheck.CHECKING -> "Checking your Readwise token…"
                    ReadwiseAccountCheck.VERIFIED -> "Connected. Readwise accepted your token."
                    null -> "Connected to Readwise."
                },
                style = HearthText.Body,
                color = if (state.accountCheck == ReadwiseAccountCheck.VERIFIED) palette.statusOK else palette.text,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
            state.accountFailure?.let { FailureText(it, null) }
            Spacer(Modifier.size(Hearth.Spacing.L))
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                QuietButton("Check connection", onClick = onValidate)
                QuietButton("Disconnect", onClick = onDisconnect)
            }
        } else {
            Text(
                "Paste the access token from your Readwise account to send highlights. Enve stores it in this profile's encrypted credential vault.",
                style = HearthText.Body,
                color = palette.textSecondary,
            )
            Spacer(Modifier.size(Hearth.Spacing.M))
            Text(
                "Get your token at readwise.io/access_token",
                style = HearthText.Label,
                color = palette.ember,
                modifier = Modifier
                    .clip(RoundedCornerShape(Hearth.Radius.Inner))
                    .clickable {
                        try {
                            uriHandler.openUri(ACCESS_TOKEN_URL)
                        } catch (_: IllegalArgumentException) {
                        }
                    }
                    .padding(vertical = Hearth.Spacing.S),
            )
            Spacer(Modifier.size(Hearth.Spacing.S))
            OutlinedTextField(
                value = state.tokenInput,
                onValueChange = onTokenChange,
                label = { Text("Access token") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    autoCorrectEnabled = false,
                    imeAction = ImeAction.Done,
                ),
                keyboardActions = KeyboardActions(onDone = { onConnect() }),
                enabled = !state.connecting,
                modifier = Modifier.fillMaxWidth(),
            )
            state.accountFailure?.let { FailureText(it, null) }
            Spacer(Modifier.size(Hearth.Spacing.L))
            val canConnect = state.tokenInput.isNotBlank() && !state.connecting
            EmberButton(
                if (state.connecting) "Checking token…" else "Connect",
                onClick = { if (canConnect) onConnect() },
                modifier = Modifier
                    .fillMaxWidth()
                    .alpha(if (canConnect) 1f else 0.45f)
                    .semantics { if (!canConnect) disabled() },
            )
        }
    }
}

@Composable
private fun ExportCard(
    connected: Boolean,
    state: ReadwiseUiState,
    onSend: () -> Unit,
    onCancel: () -> Unit,
    onDismissResult: () -> Unit,
) {
    val palette = Hearth.palette
    val preview = state.preview
    Card {
        Overline("Send highlights")
        Spacer(Modifier.size(Hearth.Spacing.M))
        when {
            preview == null -> Text(
                if (state.loadingPreview) "Counting highlights…" else "No highlights to preview.",
                style = HearthText.Body,
                color = palette.textSecondary,
            )
            else -> PreviewSummary(preview)
        }

        val progress = state.progress
        val result = state.result
        if (progress != null) {
            Spacer(Modifier.size(Hearth.Spacing.L))
            ExportProgress(progress)
            Spacer(Modifier.size(Hearth.Spacing.M))
            QuietButton("Stop sending", onClick = onCancel)
        } else if (result != null) {
            Spacer(Modifier.size(Hearth.Spacing.L))
            ResultSummary(result)
            Spacer(Modifier.size(Hearth.Spacing.M))
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                if (result.failure != null && result.unsentCount > 0 && connected) {
                    QuietButton("Try again", onClick = onSend)
                }
                QuietButton("Done", onClick = onDismissResult)
            }
        } else if (preview != null) {
            Spacer(Modifier.size(Hearth.Spacing.L))
            val canSend = connected && preview.readyCount > 0 && !state.loadingPreview
            EmberButton(
                when {
                    !connected -> "Connect Readwise to send"
                    preview.readyCount == 0 && preview.alreadySentCount > 0 && preview.excludedCount == 0 -> "Everything is already sent"
                    preview.readyCount == 0 -> "No highlights ready to send"
                    else -> "Send ${countLabel(preview.readyCount)} to Readwise"
                },
                onClick = { if (canSend) onSend() },
                modifier = Modifier
                    .fillMaxWidth()
                    .alpha(if (canSend) 1f else 0.45f)
                    .semantics { if (!canSend) disabled() },
            )
        }
    }
}

@Composable
private fun PreviewSummary(preview: ReadwiseExportPreview) {
    val palette = Hearth.palette
    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        Text(
            if (preview.readyCount == 0) {
                "Nothing new to send."
            } else {
                "${countLabel(preview.readyCount)} ready from ${preview.bookCount} ${if (preview.bookCount == 1) "book" else "books"}."
            },
            style = HearthText.Label,
            color = palette.text,
        )
        val details = buildList {
            if (preview.newCount > 0) add("${preview.newCount} new")
            if (preview.changedCount > 0) add("${preview.changedCount} edited since last sent")
            if (preview.alreadySentCount > 0) add("${preview.alreadySentCount} already sent")
            if (preview.excludedCount > 0) add("${preview.excludedCount} skipped")
        }
        if (details.isNotEmpty()) {
            Text(details.joinToString(" · "), style = HearthText.Caption, color = palette.textSecondary)
        }
        if (preview.excludedCount > 0) {
            Text(
                "Bookmarks, empty highlights, and text or notes over 8,191 characters are skipped.",
                style = HearthText.Caption,
                color = palette.textSecondary,
            )
        }
        preview.samples.forEach { SampleRow(it) }
        if (preview.readyCount > preview.samples.size && preview.samples.isNotEmpty()) {
            Text(
                "and ${preview.readyCount - preview.samples.size} more",
                style = HearthText.Caption,
                color = palette.textTertiary,
            )
        }
    }
}

@Composable
private fun SampleRow(sample: ReadwisePreviewHighlight) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(palette.bgSunken)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS),
    ) {
        Text(
            "“${sample.text}”",
            style = HearthText.Body.copy(fontStyle = FontStyle.Italic),
            color = palette.text,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        sample.note?.let {
            Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Text(
            listOfNotNull(sample.bookTitle ?: "Untitled book", sample.bookAuthor).joinToString(" · "),
            style = HearthText.Caption,
            color = palette.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun ExportProgress(progress: ReadwiseExportProgress) {
    val palette = Hearth.palette
    Column(
        Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Text(
            if (progress.total == 0) "Preparing highlights…" else "Sent ${progress.sent} of ${progress.total}",
            style = HearthText.Label,
            color = palette.text,
        )
        LinearProgressIndicator(
            progress = { if (progress.total == 0) 0f else progress.sent.toFloat() / progress.total },
            modifier = Modifier.fillMaxWidth(),
            color = palette.ember,
            trackColor = palette.hairline,
        )
    }
}

@Composable
private fun ResultSummary(result: ReadwiseExportResult) {
    val palette = Hearth.palette
    Column(
        Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
    ) {
        val failure = result.failure
        Text(
            when {
                failure == null && result.sentCount == 0 -> "Nothing new to send."
                failure == null -> "Sent ${countLabel(result.sentCount)} to Readwise."
                result.sentCount > 0 -> "Sent ${countLabel(result.sentCount)}. ${countLabel(result.unsentCount)} not sent yet."
                else -> "No highlights were sent."
            },
            style = HearthText.Label,
            color = if (failure == null) palette.statusOK else palette.text,
        )
        failure?.let { FailureText(it, result.retryAfterSeconds) }
    }
}

@Composable
private fun FailureText(failure: ReadwiseFailure, retryAfterSeconds: Long?) {
    Text(
        failure.message(retryAfterSeconds),
        style = HearthText.Caption,
        color = Hearth.palette.statusError,
        modifier = Modifier.padding(top = Hearth.Spacing.S).semantics { liveRegion = LiveRegionMode.Polite },
    )
}

@Composable
private fun ConfirmExportDialog(preview: ReadwiseExportPreview, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    val palette = Hearth.palette
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = onConfirm) { Text("Send", color = palette.ember) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel", color = palette.textSecondary) }
        },
        title = { Text("Send ${countLabel(preview.readyCount)} to Readwise?", color = palette.text) },
        text = {
            Text(
                "Highlighted text, notes, book titles and authors from ${preview.bookCount} ${if (preview.bookCount == 1) "book" else "books"} will be sent to your Readwise account.",
                color = palette.textSecondary,
            )
        },
        containerColor = palette.bgElevated,
    )
}

@Composable
private fun Card(content: @Composable ColumnScope.() -> Unit) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Card)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape).padding(Hearth.Spacing.L),
        content = content,
    )
}

private fun countLabel(count: Int): String = if (count == 1) "1 highlight" else "$count highlights"

private fun ReadwiseFailure.message(retryAfterSeconds: Long?): String = when (this) {
    ReadwiseFailure.NOT_CONNECTED -> "Connect your Readwise account first."
    ReadwiseFailure.INVALID_TOKEN -> "Readwise didn't accept this token. Copy a fresh one from readwise.io/access_token and connect again."
    ReadwiseFailure.RATE_LIMITED -> retryAfterSeconds?.let { "Readwise is busy. Try again in $it seconds." }
        ?: "Readwise is busy. Try again in a minute."
    ReadwiseFailure.REJECTED -> "Readwise refused part of this export. Highlights sent before it are saved."
    ReadwiseFailure.SERVER -> "Readwise had a problem. Try again later."
    ReadwiseFailure.STORAGE -> "Couldn’t save export progress on this device. Free some storage and try again."
    ReadwiseFailure.NETWORK -> "Couldn't reach Readwise. Check your connection and try again."
}

private const val ACCESS_TOKEN_URL = "https://readwise.io/access_token"
