package com.enve.hearth.player

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.engine.playback.AudiobookClip
import com.enve.engine.playback.ClipShare
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import kotlin.math.roundToInt

private const val MAX_CLIP_SECONDS = AudiobookClip.MAX_DURATION_MS / 1000f

internal data class ClipDraft(
    val bookKey: String,
    val bookmarkId: String?,
    val anchorMs: Long,
    val bookDurationMs: Long,
    val startMs: Long?,
    val endMs: Long?,
    val note: String?,
)

@Composable
internal fun ClipEditor(draft: ClipDraft, onCancel: () -> Unit, onSave: (startMs: Long, endMs: Long, note: String?) -> Unit) {
    val palette = Hearth.palette
    val anchorSec = draft.anchorMs / 1000f
    val maxBackward = minOf(anchorSec, MAX_CLIP_SECONDS)
    val maxForward = minOf(((draft.bookDurationMs - draft.anchorMs) / 1000f).coerceAtLeast(0f), MAX_CLIP_SECONDS)
    var backward by remember { mutableFloatStateOf(((draft.anchorMs - (draft.startMs ?: draft.anchorMs)) / 1000f).coerceIn(0f, maxBackward)) }
    var forward by remember {
        mutableFloatStateOf(((draft.endMs ?: (draft.anchorMs + 60_000L)) - draft.anchorMs).div(1000f).coerceIn(0f, maxForward))
    }
    var note by remember { mutableStateOf(draft.note.orEmpty()) }
    val startMs = draft.anchorMs - (backward * 1000).toLong()
    val endMs = draft.anchorMs + (forward * 1000).toLong()
    val canSave = endMs > startMs

    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            Overline(if (draft.startMs == null) "New clip" else "Edit clip")
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                QuietButton("Cancel", onCancel)
                EmberButton("Save", onClick = { if (canSave) onSave(startMs, endMs, note.trim().takeIf { it.isNotEmpty() }) })
            }
        }
        OutlinedTextField(
            value = note,
            onValueChange = { note = it.take(1500) },
            label = { Text("Note") },
            minLines = 2,
            modifier = Modifier.fillMaxWidth(),
        )
        ClipValueRow("Anchored at", fmtSec(draft.anchorMs / 1000))
        ClipReachSlider(
            label = "Starts",
            time = fmtSec(startMs / 1000),
            value = backward,
            max = maxBackward,
            caption = if (backward == 0f) "Begins at the bookmark." else "Begins ${fmtSec(backward.toLong())} before the bookmark.",
            accessibilityLabel = "Seconds before the bookmark",
        ) { value ->
            backward = value
            if (backward + forward > MAX_CLIP_SECONDS) forward = (MAX_CLIP_SECONDS - backward).coerceAtLeast(0f)
        }
        ClipReachSlider(
            label = "Ends",
            time = fmtSec(endMs / 1000),
            value = forward,
            max = maxForward,
            caption = if (forward == 0f) "Ends at the bookmark." else "Ends ${fmtSec(forward.toLong())} after the bookmark.",
            accessibilityLabel = "Seconds after the bookmark",
        ) { value ->
            forward = value
            if (backward + forward > MAX_CLIP_SECONDS) backward = (MAX_CLIP_SECONDS - forward).coerceAtLeast(0f)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Length", style = HearthText.Label, color = palette.textSecondary)
            Text(fmtSec((endMs - startMs) / 1000), style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold), color = palette.ember)
        }
    }
}

@Composable
private fun ClipValueRow(label: String, value: String) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = HearthText.Label, color = palette.textSecondary)
        Text(value, style = HearthText.Label, color = palette.text)
    }
}

@Composable
private fun ClipReachSlider(
    label: String,
    time: String,
    value: Float,
    max: Float,
    caption: String,
    accessibilityLabel: String,
    onChange: (Float) -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    Column {
        ClipValueRow(label, time)
        Slider(
            value = value,
            onValueChange = { onChange(it.roundToInt().toFloat().coerceIn(0f, max)) },
            valueRange = 0f..max.coerceAtLeast(1f),
            enabled = max > 0f,
            colors = SliderDefaults.colors(
                thumbColor = if (eink.active) palette.text else palette.ember,
                activeTrackColor = if (eink.active) palette.text else palette.ember,
                inactiveTrackColor = palette.hairline,
            ),
            modifier = Modifier.semantics { contentDescription = accessibilityLabel },
        )
        Text(caption, style = HearthText.Caption, color = palette.textTertiary)
    }
}

@Composable
internal fun ClipDialogs(vm: HearthPlayerViewModel) {
    val context = LocalContext.current
    val message by vm.clipMessage.collectAsStateWithLifecycle()
    val transcript by vm.clipTranscript.collectAsStateWithLifecycle()
    LaunchedEffect(vm) { vm.clipShares.collect { startClipShare(context, it) } }

    message?.let { text ->
        AlertDialog(
            onDismissRequest = vm::dismissClipMessage,
            title = { Text("Clips") },
            text = { Text(text) },
            confirmButton = { TextButton(onClick = vm::dismissClipMessage) { Text("All right") } },
        )
    }
    transcript?.let { shown ->
        AlertDialog(
            onDismissRequest = vm::dismissClipTranscript,
            title = { Text(shown.title) },
            text = {
                SelectionContainer {
                    Text(
                        shown.text,
                        style = HearthText.Body,
                        modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()),
                    )
                }
            },
            confirmButton = { TextButton(onClick = vm::dismissClipTranscript) { Text("Done") } },
            dismissButton = {
                TextButton(onClick = { startTextShare(context, shown) }) { Text("Share") }
            },
        )
    }
}

@Composable
internal fun TranscriptionModelDialog(sizeBytes: Long, onDownload: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Download speech model?") },
        text = {
            Column {
                Text("Clips are transcribed on this device with an English speech model.")
                Spacer(Modifier.size(Hearth.Spacing.S))
                Text("The model is ${sizeBytes / 1_000_000} MB and is downloaded once.", style = HearthText.Caption)
            }
        },
        confirmButton = { TextButton(onClick = onDownload) { Text("Download") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Not now") } },
    )
}

private fun startClipShare(context: Context, share: ClipShare) {
    val uri = Uri.parse(share.uri)
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = share.mimeType
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_SUBJECT, share.title)
        clipData = ClipData.newRawUri(share.title, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(intent, "Share clip"))
}

private fun startTextShare(context: Context, transcript: ClipTranscript) {
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_SUBJECT, transcript.title)
        putExtra(Intent.EXTRA_TEXT, transcript.text)
    }
    context.startActivity(Intent.createChooser(intent, "Share transcript"))
}
