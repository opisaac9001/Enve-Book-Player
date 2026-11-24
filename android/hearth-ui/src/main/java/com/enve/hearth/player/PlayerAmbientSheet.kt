package com.enve.hearth.player

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.engine.playback.AmbientAudioState
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import kotlin.math.roundToInt

private val ambientSources = listOf(
    "Mixkit rain sounds" to "https://mixkit.co/free-sound-effects/rain/",
    "Pixabay nature ambience" to "https://pixabay.com/sound-effects/search/nature%20ambience/",
    "Freesound CC0 search" to "https://freesound.org/search/?q=rainforest&f=license:%22Creative%20Commons%200%22",
)

@Composable
internal fun AmbientSheet(vm: HearthPlayerViewModel) {
    val state by vm.ambient.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    val uriHandler = LocalUriHandler.current
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { vm.attachAmbientTrack(it.toString()) }
    }
    val chooseFile = { importer.launch(arrayOf("audio/*")) }

    Column(
        Modifier.fillMaxWidth().heightIn(max = 620.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
    ) {
        Overline("Ambient sound")
        when {
            state.bookKey == null -> Text("Start a book to lay a quiet sound under it.", style = HearthText.Body, color = palette.textSecondary)
            state.selectionName != null -> AmbientSelectionCard(state, vm, onReplace = chooseFile)
            else -> Text(
                "Lay a quiet sound under the narration. Use an included one, or any audio file of your own. " +
                    "It stays with this book and pauses when the book pauses.",
                style = HearthText.Body,
                color = palette.textSecondary,
            )
        }

        if (state.bookKey != null) {
            Column {
                Overline("Included sounds")
                Spacer(Modifier.size(Hearth.Spacing.S))
                state.presets.forEach { preset ->
                    val selected = state.selectedPresetId == preset.id
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 48.dp)
                            .semantics { stateDescription = if (selected) "Selected" else "Not selected" }
                            .clickable(role = Role.Button) { vm.attachAmbientPreset(preset.id) }
                            .padding(vertical = Hearth.Spacing.S),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(preset.title, style = HearthText.Label, color = palette.text)
                            Text(preset.subtitle, style = HearthText.Caption, color = palette.textTertiary)
                        }
                        if (selected) Icon(Icons.Outlined.Check, contentDescription = null, tint = palette.ember, modifier = Modifier.size(18.dp))
                    }
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                Overline("Your own sound")
                QuietButton("Choose an audio file", onClick = chooseFile)
                Text("Any audio file on this device. It loops quietly under the book.", style = HearthText.Caption, color = palette.textTertiary)
            }
        }

        Column {
            Overline("Find more")
            ambientSources.forEach { (title, url) ->
                Text(
                    title,
                    style = HearthText.Label,
                    color = palette.textSecondary,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                        .clickable(role = Role.Button, onClickLabel = "Open $title") { uriHandler.openUri(url) }
                        .padding(vertical = Hearth.Spacing.M),
                )
            }
        }
    }

    state.errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = vm::clearAmbientError,
            title = { Text("Ambient sound") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = vm::clearAmbientError) { Text("All right") } },
        )
    }
}

@Composable
private fun AmbientSelectionCard(state: AmbientAudioState, vm: HearthPlayerViewModel, onReplace: () -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 4.dp else Hearth.Radius.Inner)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(palette.emberSoft)
            .border(1.dp, if (eink.active) palette.text else palette.ember.copy(alpha = 0.35f), shape)
            .padding(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Column {
            Text(state.selectionName.orEmpty(), style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold), color = palette.text, maxLines = 1)
            Text(
                if (state.isPlaying) "Playing softly behind the narration" else "Waiting with the narration",
                style = HearthText.Caption,
                color = palette.textTertiary,
            )
        }
        Column {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Volume", style = HearthText.Label, color = palette.textSecondary)
                Text("${(state.volume * 100).roundToInt()}%", style = HearthText.Label, color = palette.textSecondary)
            }
            Slider(
                value = state.volume,
                onValueChange = vm::setAmbientVolume,
                colors = SliderDefaults.colors(
                    thumbColor = if (eink.active) palette.text else palette.ember,
                    activeTrackColor = if (eink.active) palette.text else palette.ember,
                    inactiveTrackColor = palette.hairline,
                ),
                modifier = Modifier.semantics { contentDescription = "Ambient volume" },
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            QuietButton("Replace", onClick = onReplace)
            QuietButton("Remove", onClick = vm::removeAmbient)
        }
    }
}
