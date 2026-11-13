package com.enve.app.ui.screens.reader

import com.enve.core.reader.ReadAloudHighlightStyle
import androidx.compose.foundation.background
import com.enve.core.reader.highlightColorHex
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.RecordVoiceOver
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.app.data.reader.CustomFont
import com.enve.app.data.reader.MAX_READER_FONT_SCALE
import com.enve.app.data.reader.MIN_READER_FONT_SCALE
import com.enve.app.data.reader.READER_FONT_SCALE_STEP
import com.enve.app.data.reader.ReaderFont
import com.enve.app.data.reader.ReaderProgressDisplay
import com.enve.app.data.reader.ReaderTheme
import androidx.compose.foundation.layout.widthIn
import com.enve.app.data.reader.ReaderPreferences
import com.enve.app.readium.narrator.NarratorPack
import com.enve.app.viewmodel.ReaderNarratorPackState
import com.enve.app.viewmodel.ReaderUiState
import com.enve.app.viewmodel.ReaderViewModel
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.ReaderAnnotation
import com.enve.hearth.design.EmberAccent
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.HearthToggleRow
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.parseHexColor
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HearthReaderSheets(vm: ReaderViewModel, state: ReaderUiState) {
    val palette = Hearth.palette
    val customFonts by vm.customFonts.collectAsStateWithLifecycle()

    val sheetShape = if (Hearth.eink.sharpCorners) {
        androidx.compose.ui.graphics.RectangleShape
    } else {
        androidx.compose.material3.BottomSheetDefaults.ExpandedShape
    }
    if (state.showAppearanceSheet) {
        ModalBottomSheet(onDismissRequest = { vm.showAppearance(false) }, shape = sheetShape, containerColor = palette.bgElevated) {
            AppearanceSheet(vm, state, customFonts)
        }
    }
    if (state.showTocSheet) {
        ModalBottomSheet(onDismissRequest = { vm.showToc(false) }, shape = sheetShape, containerColor = palette.bgElevated) {
            ContentsSheet(vm, state)
        }
    }
    if (state.showSearchSheet) {
        ModalBottomSheet(
            onDismissRequest = { vm.showSearch(false) },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            shape = sheetShape,
            containerColor = palette.bgElevated,
        ) {
            SearchSheet(vm, state)
        }
    }
    if (state.showReadAloudSheet) {
        ModalBottomSheet(onDismissRequest = { vm.showReadAloudSheet(false) }, shape = sheetShape, containerColor = palette.bgElevated) {
            ReadAloudSheet(vm, state)
        }
    }
    if (state.showTtsSheet) {
        ModalBottomSheet(onDismissRequest = { vm.showTtsSheet(false) }, shape = sheetShape, containerColor = palette.bgElevated) {
            ReaderTTSSheet(vm, state)
        }
    }
    state.definition?.let { definition ->
        ModalBottomSheet(onDismissRequest = vm::dismissDefinition, shape = sheetShape, containerColor = palette.bgElevated) {
            ReaderDefineSheet(definition, onSaveWord = vm::saveDefinedWord)
        }
    }
    if (state.showAnnotationDialog) {
        ModalBottomSheet(
            onDismissRequest = { vm.showAnnotationDialog(false); vm.hideSelectionPopup() },
            shape = sheetShape,
            containerColor = palette.bgElevated,
        ) {
            NoteSheet(vm, state)
        }
    }
}

@Composable
private fun ReaderTTSSheet(vm: ReaderViewModel, state: ReaderUiState) {
    var showingVoices by rememberSaveable { mutableStateOf(false) }
    if (showingVoices) {
        ReaderVoicePicker(vm, state, onBack = { showingVoices = false })
    } else {
        ReaderSpeechControls(vm, state, onVoices = { showingVoices = true })
    }
}

@Composable
private fun ReaderSpeechControls(vm: ReaderViewModel, state: ReaderUiState, onVoices: () -> Unit) {
    val palette = Hearth.palette
    val playback = state.ttsPlayback
    val cardShape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Card)
    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
            .padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.S, bottom = Hearth.Spacing.XXL),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XL),
    ) {
        Overline("Read to me")
        if (playback.passage.isNotBlank()) {
            Text(
                playback.passage,
                style = hearthDisplay(16.sp, FontWeight.Normal),
                color = palette.text,
                maxLines = 5,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth().clip(cardShape).background(palette.bg)
                    .border(1.dp, palette.hairline, cardShape).padding(Hearth.Spacing.L),
            )
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            SpeechGlyph(Icons.Filled.SkipPrevious, "Previous paragraph", 48.dp, enabled = playback.active, onClick = vm::previousTtsParagraph)
            Spacer(Modifier.width(Hearth.Spacing.XL))
            SpeechGlyph(
                if (playback.playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                if (playback.playing) "Pause" else "Read aloud",
                68.dp,
                prominent = true,
                onClick = vm::toggleTtsPlayback,
            )
            Spacer(Modifier.width(Hearth.Spacing.XL))
            SpeechGlyph(Icons.Filled.SkipNext, "Next paragraph", 48.dp, enabled = playback.active, onClick = vm::nextTtsParagraph)
        }
        if (playback.preparing && playback.playing) {
            Text("Preparing speech…", style = HearthText.Caption, color = palette.textSecondary, modifier = Modifier.align(Alignment.CenterHorizontally))
        }
        var pace by remember(state.prefs.ttsSpeed) { mutableFloatStateOf(state.prefs.ttsSpeed) }
        Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS)) {
            Row(Modifier.fillMaxWidth()) {
                Text("Pace", style = HearthText.Label, color = palette.text, modifier = Modifier.weight(1f))
                Text(formatPace(pace), style = HearthText.Label, color = palette.textSecondary)
            }
            androidx.compose.material3.Slider(
                value = pace,
                onValueChange = { pace = (it * 4).roundToInt() / 4f },
                onValueChangeFinished = { vm.updatePreferences(state.prefs.copy(ttsSpeed = pace)) },
                valueRange = MIN_SPEECH_PACE..MAX_SPEECH_PACE,
                steps = ((MAX_SPEECH_PACE - MIN_SPEECH_PACE) / 0.25f).roundToInt() - 1,
                colors = androidx.compose.material3.SliderDefaults.colors(
                    thumbColor = palette.ember,
                    activeTrackColor = palette.ember,
                    inactiveTrackColor = palette.hairline,
                    activeTickColor = Color.Transparent,
                    inactiveTickColor = Color.Transparent,
                ),
                modifier = Modifier.semantics { contentDescription = "Pace" },
            )
        }
        Row(
            Modifier.fillMaxWidth().clip(cardShape).background(palette.bg).border(1.dp, palette.hairline, cardShape)
                .clickable(role = Role.Button, onClickLabel = "Choose a voice", onClick = onVoices)
                .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.RecordVoiceOver, null, tint = palette.ember, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(Hearth.Spacing.M))
            Column(Modifier.weight(1f)) {
                Text(currentVoiceTitle(state), style = HearthText.Label, color = palette.text)
                Text(currentVoiceDetail(state), style = HearthText.Caption, color = palette.textSecondary)
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = palette.textTertiary)
        }
        if (playback.active) {
            QuietButton("Stop reading", onClick = { vm.stopTts(); vm.showTtsSheet(false) }, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun SpeechGlyph(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    size: androidx.compose.ui.unit.Dp,
    enabled: Boolean = true,
    prominent: Boolean = false,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    val background = if (prominent) palette.ember else palette.bg
    val tint = if (prominent) palette.readableOnEmber else palette.text
    Box(
        Modifier.size(size).clip(CircleShape).background(background)
            .then(if (prominent) Modifier else Modifier.border(1.dp, palette.hairline, CircleShape))
            .clickable(enabled = enabled, role = Role.Button, onClickLabel = label, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, tint = if (enabled) tint else tint.copy(alpha = 0.4f), modifier = Modifier.size(size * 0.42f))
    }
}

@Composable
private fun ReaderVoicePicker(vm: ReaderViewModel, state: ReaderUiState, onBack: () -> Unit) {
    val palette = Hearth.palette
    val narrator = state.ttsNarratorPack
    val languages = remember(state.ttsVoices) {
        state.ttsVoices.distinctBy { it.language }.sortedBy { it.languageName }
    }
    val selectedLanguage = state.ttsVoices.firstOrNull { it.name == state.ttsVoice }?.language
        ?: java.util.Locale.getDefault().language
    var language by rememberSaveable(selectedLanguage) { mutableStateOf(selectedLanguage) }
    var confirming by remember { mutableStateOf<NarratorPack?>(null) }
    val context = LocalContext.current
    val size = { pack: NarratorPack -> android.text.format.Formatter.formatShortFileSize(context, pack.downloadBytes) }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.M).padding(bottom = Hearth.Spacing.XS),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, "Back", tint = palette.text)
            }
            Overline("Voices")
        }
        LazyColumn(
            Modifier.fillMaxWidth().heightIn(max = 560.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = Hearth.Spacing.XL, end = Hearth.Spacing.XL, bottom = Hearth.Spacing.XXL,
            ),
        ) {
            item { VoiceSectionHeader("Engine") }
            item {
                SpeechChoiceRow("Android voice", "Built into this device", selected = narrator == null) { vm.selectNarrator(null) }
            }
            items(NarratorPack.available, key = { it.name }) { pack ->
                val status = state.ttsNarratorPacks[pack] ?: ReaderNarratorPackState.NotInstalled
                SpeechChoiceRow(pack.title, narratorStatusLabel(status, size(pack)), selected = narrator == pack) {
                    if (status == ReaderNarratorPackState.Installed) vm.selectNarrator(pack) else confirming = pack
                }
            }
            item { VoiceSectionHeader("Downloads") }
            items(NarratorPack.available, key = { "download-${it.name}" }) { pack ->
                NarratorDownloadRow(
                    vm = vm,
                    pack = pack,
                    status = state.ttsNarratorPacks[pack] ?: ReaderNarratorPackState.NotInstalled,
                    size = size(pack),
                    onDownload = { confirming = pack },
                )
            }
            if (narrator == null && languages.size > 1) {
                item { VoiceSectionHeader("Language") }
                items(languages, key = { "language-${it.language}" }) { voice ->
                    SpeechChoiceRow(voice.languageName, null, selected = language == voice.language) { language = voice.language }
                }
            }
            item { VoiceSectionHeader("Voice") }
            if (narrator != null) {
                items(narrator.voices, key = { "narrator-$it" }) { voice ->
                    SpeechChoiceRow(
                        narratorVoiceLabel(narrator, voice),
                        narratorVoiceDetail(narrator, voice),
                        selected = state.ttsNarratorVoice == voice,
                    ) { vm.selectNarratorVoice(voice) }
                }
            } else {
                val voices = state.ttsVoices.filter { it.language == language }
                if (voices.isEmpty()) {
                    item {
                        Text(
                            "Install a text-to-speech voice in Android settings.",
                            style = HearthText.Body,
                            color = palette.textSecondary,
                            modifier = Modifier.padding(vertical = Hearth.Spacing.S),
                        )
                    }
                }
                items(voices, key = { it.name }) { voice ->
                    SpeechChoiceRow(voice.title, voice.detail, selected = state.ttsVoice == voice.name) { vm.selectTtsVoice(voice.name) }
                }
            }
        }
    }
    confirming?.let { pack ->
        NarratorTermsDialog(
            pack = pack,
            size = size(pack),
            onAgree = {
                confirming = null
                vm.downloadNarrator(pack)
            },
            onDismiss = { confirming = null },
        )
    }
}

@Composable
private fun VoiceSectionHeader(title: String) {
    Box(Modifier.padding(top = Hearth.Spacing.L, bottom = Hearth.Spacing.XS)) { Overline(title) }
}

@Composable
private fun SpeechChoiceRow(label: String, detail: String?, selected: Boolean, onSelect: () -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().heightIn(min = 52.dp)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onSelect)
            .padding(vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, style = HearthText.Label, color = palette.text)
            if (!detail.isNullOrBlank()) Text(detail, style = HearthText.Caption, color = palette.textSecondary)
        }
        if (selected) Icon(Icons.Outlined.Check, "Selected", tint = palette.ember)
    }
}

@Composable
private fun NarratorDownloadRow(
    vm: ReaderViewModel,
    pack: NarratorPack,
    status: ReaderNarratorPackState,
    size: String,
    onDownload: () -> Unit,
) {
    val palette = Hearth.palette
    val uriHandler = LocalUriHandler.current
    Column(Modifier.fillMaxWidth().padding(vertical = Hearth.Spacing.S), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(pack.title, style = HearthText.Label, color = palette.text)
                Text(
                    "${pack.license} · ${narratorCredit(pack) ?: "Model terms"}",
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                    modifier = Modifier.clickable(role = Role.Button, onClickLabel = "Open ${pack.title} terms") {
                        uriHandler.openUri(if (pack == NarratorPack.WOOF) "https://underdog.ai" else pack.termsUrl)
                    },
                )
            }
            when (status) {
                ReaderNarratorPackState.NotInstalled, is ReaderNarratorPackState.Failed ->
                    androidx.compose.material3.TextButton(onClick = onDownload) {
                        Text(if (status is ReaderNarratorPackState.Failed) "Retry" else "Get · $size", color = palette.ember)
                    }
                ReaderNarratorPackState.Installed ->
                    androidx.compose.material3.TextButton(onClick = { vm.removeNarrator(pack) }) {
                        Text("Remove", color = palette.textSecondary)
                    }
                ReaderNarratorPackState.Removing ->
                    Text("Removing…", style = HearthText.Caption, color = palette.textSecondary)
                is ReaderNarratorPackState.Downloading ->
                    Text("${(status.progress * 100).roundToInt()}%", style = HearthText.Caption, color = palette.textSecondary)
            }
        }
        when (status) {
            is ReaderNarratorPackState.Downloading -> LinearProgressIndicator(
                progress = { status.progress },
                color = palette.ember,
                trackColor = palette.hairline,
                modifier = Modifier.fillMaxWidth(),
            )
            is ReaderNarratorPackState.Failed -> Text(status.message, style = HearthText.Caption, color = palette.statusError)
            else -> Unit
        }
    }
}

@Composable
internal fun WoofAttribution() {
    val uriHandler = LocalUriHandler.current
    androidx.compose.material3.TextButton(onClick = { uriHandler.openUri("https://underdog.ai") }) {
        Text("Voice by Underdog Woof", style = HearthText.Caption, color = Hearth.palette.textSecondary)
    }
}

private const val MIN_SPEECH_PACE = 0.5f
private const val MAX_SPEECH_PACE = 3f

private fun formatPace(pace: Float): String =
    "${java.math.BigDecimal(pace.toDouble()).setScale(2, java.math.RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()}×"

private fun narratorCredit(pack: NarratorPack): String? = when (pack) {
    NarratorPack.POCKET -> "Alba MacKenna’s voice, by Kyutai"
    NarratorPack.WOOF -> "Voice by Underdog Woof"
    else -> null
}

private fun narratorStatusLabel(status: ReaderNarratorPackState, size: String): String = when (status) {
    ReaderNarratorPackState.Installed -> "Downloaded · reads offline"
    ReaderNarratorPackState.NotInstalled -> "$size download"
    is ReaderNarratorPackState.Downloading -> "Downloading ${(status.progress * 100).roundToInt()}%"
    ReaderNarratorPackState.Removing -> "Removing…"
    is ReaderNarratorPackState.Failed -> "Download failed"
}

private fun narratorVoiceLabel(pack: NarratorPack, voice: String): String = when (pack) {
    NarratorPack.KOKORO -> voice.substringAfter('_').replaceFirstChar(Char::uppercase)
    NarratorPack.SUPERTONIC -> "Voice $voice"
    NarratorPack.POCKET, NarratorPack.PHONON, NarratorPack.WOOF -> voice.replaceFirstChar(Char::uppercase)
}

private fun narratorVoiceDetail(pack: NarratorPack, voice: String): String? = when (pack) {
    NarratorPack.KOKORO -> {
        val accent = when (voice.firstOrNull()) {
            'a' -> "American"
            'b' -> "British"
            else -> null
        }
        val gender = when (voice.getOrNull(1)) {
            'f' -> "female"
            'm' -> "male"
            else -> null
        }
        listOfNotNull(accent, gender).joinToString(" ").replaceFirstChar(Char::uppercase).ifBlank { null }
    }
    NarratorPack.SUPERTONIC -> when (voice.firstOrNull()) {
        'F' -> "Female"
        'M' -> "Male"
        else -> null
    }
    else -> null
}

private fun currentVoiceTitle(state: ReaderUiState): String {
    val pack = state.ttsNarratorPack ?: return state.ttsVoices.firstOrNull { it.name == state.ttsVoice }
        ?.let { "${it.languageName} · ${it.title}" } ?: "Android voice"
    val voice = state.ttsNarratorVoice ?: pack.voices.first()
    return "${narratorVoiceLabel(pack, voice)} · ${pack.title}"
}

private fun currentVoiceDetail(state: ReaderUiState): String {
    val pack = state.ttsNarratorPack ?: return state.ttsVoices.firstOrNull { it.name == state.ttsVoice }?.detail
        ?.let { "Android voice · $it" } ?: "Built into this device"
    return narratorVoiceDetail(pack, state.ttsNarratorVoice ?: pack.voices.first())
        ?.let { "$it · on-device" } ?: "On-device narrator"
}

@Composable
private fun NarratorTermsDialog(pack: NarratorPack, size: String, onAgree: () -> Unit, onDismiss: () -> Unit) {
    val palette = Hearth.palette
    val uriHandler = LocalUriHandler.current
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { EmberButton("Agree and download", onClick = onAgree) },
        dismissButton = { QuietButton("Cancel", onClick = onDismiss) },
        title = { Text("${pack.title} terms", style = HearthText.BookTitle, color = palette.text) },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                Text(pack.terms, style = HearthText.Body, color = palette.text)
                Text("Agreeing starts a $size download.", style = HearthText.Caption, color = palette.textSecondary)
                androidx.compose.material3.TextButton(onClick = { uriHandler.openUri(pack.termsUrl) }) {
                    Text("Read the ${pack.license} license", color = palette.ember)
                }
            }
        },
        shape = if (Hearth.eink.sharpCorners) androidx.compose.ui.graphics.RectangleShape else RoundedCornerShape(Hearth.Radius.Card),
        containerColor = palette.bgElevated,
    )
}

@Composable
private fun NoteSheet(vm: ReaderViewModel, state: ReaderUiState) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    var note by remember { mutableStateOf("") }
    var ink by remember { mutableStateOf(NARRATION_INKS[0]) }
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(bottom = Hearth.Spacing.XXL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L)) {
        Overline("Add a note")
        if (state.selectionText.isNotBlank()) {
            Text(
                "“${state.selectionText}”",
                style = HearthText.Caption,
                color = palette.textSecondary,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Box(Modifier.fillMaxWidth().clip(shape).background(palette.bg).border(1.dp, palette.hairline, shape).padding(Hearth.Spacing.M)) {
            if (note.isEmpty()) Text("Your note…", style = HearthText.Body, color = palette.textTertiary)
            BasicTextField(
                value = note,
                onValueChange = { note = it },
                textStyle = HearthText.Body.copy(color = palette.text),
                cursorBrush = SolidColor(palette.ember),
                modifier = Modifier.fillMaxWidth().heightIn(min = 72.dp),
            )
        }
        Row {
            NARRATION_INKS.forEach { hex ->
                InkSwatch(hex, selected = hex == ink) { ink = hex }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            Text(
                "Cancel", style = HearthText.Label, color = palette.textSecondary,
                modifier = Modifier.sizeIn(minHeight = 48.dp).clip(RoundedCornerShape(50))
                    .clickable(role = Role.Button) { vm.showAnnotationDialog(false); vm.hideSelectionPopup() }
                    .wrapContentHeight().padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M),
            )
            Spacer(Modifier.weight(1f))
            Text(
                "Save note", style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold), color = palette.readableOnEmber,
                modifier = Modifier.sizeIn(minHeight = 48.dp).clip(RoundedCornerShape(50)).background(palette.ember)
                    .clickable(role = Role.Button) {
                        state.pendingSelection?.let { vm.addAnnotation(it, AnnotationStyle.HIGHLIGHT, ink, note, state.selectionText) }
                        vm.showAnnotationDialog(false)
                        vm.hideSelectionPopup()
                    }
                    .wrapContentHeight().padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M),
            )
        }
    }
}

private val NARRATION_INKS = listOf("#FFF59D", "#A5D6A7", "#90CAF9", "#F8BBD0")

@Composable
private fun InkSwatch(hex: String, selected: Boolean, onSelect: () -> Unit) {
    val palette = Hearth.palette
    val colorName = when (hex) {
        "#FFF59D" -> "Yellow"
        "#A5D6A7" -> "Green"
        "#90CAF9" -> "Blue"
        "#F8BBD0" -> "Pink"
        else -> "Highlight"
    }
    Box(
        Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp).clip(CircleShape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onSelect)
            .semantics { contentDescription = "$colorName highlight color" },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(30.dp).clip(CircleShape).background(parseHexColor(hex) ?: EmberAccent)
                .border(if (selected) 2.dp else 0.dp, if (selected) palette.ember else Color.Transparent, CircleShape),
        )
    }
}

@Composable
private fun ReadAloudSheet(vm: ReaderViewModel, state: ReaderUiState) {
    val palette = Hearth.palette
    val prefs = state.prefs
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = Hearth.Spacing.XL).padding(bottom = Hearth.Spacing.XXL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L)) {
        Overline("Read Aloud")

        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            listOf(0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f, 2.5f, 3.0f).forEach { s ->
                HearthChip(
                    if (s == s.toInt().toFloat()) "${s.toInt()}×" else "$s×",
                    selected = kotlin.math.abs(prefs.readAloudSpeed - s) < 0.01f,
                    onClick = { vm.setReadAlongSpeed(s) },
                )
            }
        }

        Stepper(
            "Sync offset", "%+.1fs".format(prefs.readAloudSyncOffsetMs / 1000f),
            { vm.updatePreferences(prefs.copy(readAloudSyncOffsetMs = (prefs.readAloudSyncOffsetMs - 100).coerceIn(-1000, 1000))) },
            { vm.updatePreferences(prefs.copy(readAloudSyncOffsetMs = (prefs.readAloudSyncOffsetMs + 100).coerceIn(-1000, 1000))) },
        )

        HearthToggleRow("Mark spoken text", prefs.readAloudHighlight) { vm.updatePreferences(prefs.copy(readAloudHighlight = it)) }
        if (prefs.readAloudHighlight) {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                ReadAloudHighlightStyle.entries.forEach { style ->
                    HearthChip(
                        style.label,
                        selected = prefs.readAloudHighlightStyle == style,
                        onClick = { vm.updatePreferences(prefs.copy(readAloudHighlightStyle = style)) },
                    )
                }
            }
            if (prefs.readAloudHighlightStyle == ReadAloudHighlightStyle.HIGHLIGHT) Row {
                NARRATION_INKS.forEach { hex ->
                    InkSwatch(hex, selected = hex.equals(prefs.readAloudHighlightHex, ignoreCase = true)) {
                        vm.updatePreferences(prefs.copy(readAloudHighlightHex = hex))
                    }
                }
            }
        }
        HearthToggleRow("Turn pages with read aloud", prefs.readAloudAutoTurn) { vm.updatePreferences(prefs.copy(readAloudAutoTurn = it)) }
        HearthToggleRow("Skip audio on page turn", prefs.readAloudSkipOnPageTurn) { vm.updatePreferences(prefs.copy(readAloudSkipOnPageTurn = it)) }
        HearthToggleRow("Skip footnotes & page numbers", prefs.readAloudSkipAsides) { vm.updatePreferences(prefs.copy(readAloudSkipAsides = it)) }

        Overline("Clips in this chapter")
        if (state.readAlongChapterClips.isEmpty()) {
            Empty("Start read aloud to load this chapter's clips.")
        } else {
            LazyColumn(Modifier.heightIn(max = 300.dp)) {
                items(state.readAlongChapterClips) { row ->
                    val current = row.index == state.readAlongClipIndex
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { vm.jumpToReadAlongClip(row); vm.showReadAloudSheet(false) }
                            .padding(vertical = Hearth.Spacing.S),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        val label = row.text.ifBlank { "Clip ${row.index + 1}" }
                        Text(
                            if (current) "▸ $label" else label,
                            style = if (current) HearthText.Body.copy(fontWeight = FontWeight.SemiBold) else HearthText.Body,
                            color = if (current) palette.ember else palette.text,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        if (row.skippable) {
                            Text("Aside", style = HearthText.Overline, color = palette.textTertiary)
                            Spacer(Modifier.size(Hearth.Spacing.M))
                        }
                        Text(clipTime(row.startMs), style = HearthText.Caption, color = palette.textSecondary)
                    }
                }
            }
        }
    }
}

private fun clipTime(ms: Long): String {
    val totalSec = ms / 1000
    return "%d:%02d".format(totalSec / 60, totalSec % 60)
}

@Composable
private fun AppearanceSheet(vm: ReaderViewModel, state: ReaderUiState, customFonts: List<CustomFont>) {
    val palette = Hearth.palette
    val prefs = state.prefs
    val haptics = rememberReaderHaptics()
    val update: (ReaderPreferences) -> Unit = { next ->
        if (next != prefs) haptics.tick()
        vm.updatePreferences(next)
    }
    Column(
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = Hearth.Spacing.XL)
            .padding(bottom = Hearth.Spacing.XXL),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Overline("Theme")
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            ThemeCard("Paper", ReaderTheme.LIGHT, Color(0xFFFAF7F2), Color(0xFF231F1B), prefs.theme) { update(prefs.copy(theme = it)) }
            ThemeCard("Sepia", ReaderTheme.SEPIA, Color(0xFFEDD9B4), Color(0xFF4A3F30), prefs.theme) { update(prefs.copy(theme = it)) }
            ThemeCard("Ink", ReaderTheme.DARK, Color(0xFF191512), Color(0xFFF0E9DC), prefs.theme) { update(prefs.copy(theme = it)) }
            ThemeCard("Black", ReaderTheme.OLED, Color.Black, Color(0xFFF0E9DC), prefs.theme) { update(prefs.copy(theme = it)) }
        }

        AppearanceSection("Text")
        Stepper("Text size", "${(prefs.fontSize * 100).roundToInt()}%",
            { update(prefs.copy(fontSize = (prefs.fontSize - READER_FONT_SCALE_STEP).coerceIn(MIN_READER_FONT_SCALE, MAX_READER_FONT_SCALE))) },
            { update(prefs.copy(fontSize = (prefs.fontSize + READER_FONT_SCALE_STEP).coerceIn(MIN_READER_FONT_SCALE, MAX_READER_FONT_SCALE))) })
        Stepper("Line spacing", trimmedNumber(prefs.lineHeight, 2),
            { update(prefs.copy(lineHeight = (prefs.lineHeight - 0.05f).coerceIn(1.0f, 2.5f))) },
            { update(prefs.copy(lineHeight = (prefs.lineHeight + 0.05f).coerceIn(1.0f, 2.5f))) })
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            ReaderFont.entries.forEach { font ->
                TypefaceCard(
                    font.displayName,
                    readerFontFamily(font),
                    selected = font == prefs.font && prefs.customFontName == null,
                ) { update(prefs.copy(font = font, customFontName = null)) }
            }
            customFonts.forEach { font ->
                TypefaceCard(font.displayName, null, selected = prefs.customFontName == font.displayName) {
                    update(prefs.copy(customFontName = font.displayName))
                }
            }
        }

        AppearanceSection("Layout")
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            HearthChip("Paged", selected = !prefs.scroll, onClick = { update(prefs.copy(scroll = false)) })
            HearthChip("Scrolled", selected = prefs.scroll, onClick = { update(prefs.copy(scroll = true)) })
        }
        Stepper("Side margins", spacingLabel(prefs.pageMargins, "×"),
            { update(prefs.copy(pageMargins = (prefs.pageMargins - 0.1f).coerceIn(0f, 2.0f))) },
            { update(prefs.copy(pageMargins = (prefs.pageMargins + 0.1f).coerceIn(0f, 2.0f))) })
        Stepper("Top & bottom margins", spacingLabel(prefs.verticalMargins, "×"),
            { update(prefs.copy(verticalMargins = (prefs.verticalMargins - 0.1f).coerceIn(0f, 2.0f))) },
            { update(prefs.copy(verticalMargins = (prefs.verticalMargins + 0.1f).coerceIn(0f, 2.0f))) })
        Stepper("Paragraph spacing", spacingLabel(prefs.paragraphSpacing, " em"),
            { update(prefs.copy(paragraphSpacing = (prefs.paragraphSpacing - 0.25f).coerceIn(0f, 2f))) },
            { update(prefs.copy(paragraphSpacing = (prefs.paragraphSpacing + 0.25f).coerceIn(0f, 2f))) })
        Stepper("Paragraph indent", spacingLabel(prefs.paragraphIndent, " em"),
            { update(prefs.copy(paragraphIndent = (prefs.paragraphIndent - 0.25f).coerceIn(0f, 3f))) },
            { update(prefs.copy(paragraphIndent = (prefs.paragraphIndent + 0.25f).coerceIn(0f, 3f))) })
        Stepper("Word spacing", spacingLabel(prefs.wordSpacing, " em"),
            { update(prefs.copy(wordSpacing = (prefs.wordSpacing - 0.05f).coerceIn(0f, 0.5f))) },
            { update(prefs.copy(wordSpacing = (prefs.wordSpacing + 0.05f).coerceIn(0f, 0.5f))) })
        Stepper("Letter spacing", spacingLabel(prefs.letterSpacing, " em"),
            { update(prefs.copy(letterSpacing = (prefs.letterSpacing - 0.01f).coerceIn(0f, 0.15f))) },
            { update(prefs.copy(letterSpacing = (prefs.letterSpacing + 0.01f).coerceIn(0f, 0.15f))) })

        AppearanceSection("Typesetting")
        HearthToggleRow("Justified text", prefs.justified) { update(prefs.copy(justified = it)) }
        HearthToggleRow("Hyphenation", prefs.hyphenate) { update(prefs.copy(hyphenate = it)) }
        HearthToggleRow("Respect publisher styles", prefs.publisherStyles) { update(prefs.copy(publisherStyles = it)) }
        HearthToggleRow("Bionic reading", prefs.bionicReading) { update(prefs.copy(bionicReading = it)) }
        Text("Bolds the first letters of each word to anchor the eye.", style = HearthText.Caption, color = palette.textSecondary)

        AppearanceSection("Page turns")
        HearthToggleRow("Animate page turns", prefs.animatedPageTurns) { update(prefs.copy(animatedPageTurns = it)) }
        HearthToggleRow("Volume buttons turn pages", prefs.volumeButtonNavigation) { update(prefs.copy(volumeButtonNavigation = it)) }
        Text(
            "Volume down: next page. Volume up: previous page. During audio playback, the buttons control volume.",
            style = HearthText.Caption,
            color = palette.textSecondary,
        )
        Text("Edge tap width", style = HearthText.Body, color = palette.text)
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            listOf("Narrow" to 0.13f, "Medium" to 0.20f, "Wide" to 0.30f).forEach { (label, width) ->
                HearthChip(
                    label,
                    selected = kotlin.math.abs(prefs.tapZoneWidth - width) < 0.01f,
                    onClick = { update(prefs.copy(tapZoneWidth = width)) },
                )
            }
        }
        HearthToggleRow("Swipe the left edge for brightness", prefs.edgeBrightnessSwipe) { update(prefs.copy(edgeBrightnessSwipe = it)) }

        AppearanceSection("Reader dimmer")
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            listOf("Off" to -1f, "25%" to 0.75f, "50%" to 0.50f, "75%" to 0.25f).forEach { (label, value) ->
                val selected = if (value < 0f) prefs.screenBrightness < 0f
                else kotlin.math.abs(prefs.screenBrightness - value) < 0.01f
                HearthChip(label, selected = selected, onClick = { update(prefs.copy(screenBrightness = value)) })
            }
        }

        AppearanceSection("While reading")
        Text("Show at the top of the page", style = HearthText.Caption, color = palette.textSecondary)
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            ReaderProgressDisplay.entries.forEach { mode ->
                HearthChip(mode.label, selected = prefs.progressDisplay == mode, onClick = { update(prefs.copy(progressDisplay = mode)) })
            }
        }
        HearthToggleRow("Clock", prefs.showClock) { update(prefs.copy(showClock = it)) }
        HearthToggleRow("Battery", prefs.showBattery) { update(prefs.copy(showBattery = it)) }
    }
}

@Composable
private fun AppearanceSection(title: String) {
    Box(Modifier.padding(top = Hearth.Spacing.M)) { Overline(title) }
}

@Composable
private fun TypefaceCard(
    label: String,
    family: androidx.compose.ui.text.font.FontFamily?,
    selected: Boolean,
    onSelect: () -> Unit,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else 12.dp)
    Column(
        Modifier.widthIn(min = 84.dp).clip(shape)
            .background(if (selected) palette.ember.copy(alpha = 0.12f) else palette.bg)
            .border(if (selected) 2.dp else 1.dp, if (selected) palette.ember else palette.hairline, shape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onSelect)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Aa", style = HearthText.Body.copy(fontFamily = family, fontSize = 22.sp), color = palette.text)
        Text(label, style = HearthText.Caption.copy(fontFamily = family), color = if (selected) palette.ember else palette.textSecondary, maxLines = 1)
    }
}

@Composable
private fun readerFontFamily(font: ReaderFont): androidx.compose.ui.text.font.FontFamily? {
    val assets = LocalContext.current.assets
    return remember(font) {
        fun asset(name: String) = runCatching {
            androidx.compose.ui.text.font.FontFamily(androidx.compose.ui.text.font.Font("reader-fonts/$name", assets))
        }.getOrNull()
        when (font) {
            ReaderFont.SERIF -> androidx.compose.ui.text.font.FontFamily.Serif
            ReaderFont.SANS -> androidx.compose.ui.text.font.FontFamily.SansSerif
            ReaderFont.MONO, ReaderFont.IA_WRITER -> androidx.compose.ui.text.font.FontFamily.Monospace
            ReaderFont.LITERATA -> asset("Literata.ttf")
            ReaderFont.ATKINSON -> asset("AtkinsonHyperlegible.ttf")
            ReaderFont.LEXEND -> asset("Lexend.ttf")
            ReaderFont.DYSLEXIC -> null
        }
    }
}

private fun trimmedNumber(value: Float, decimals: Int): String =
    java.math.BigDecimal(value.toDouble()).setScale(decimals, java.math.RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()

private fun spacingLabel(value: Float, unit: String): String =
    if (value < 0.005f) "None" else "${trimmedNumber(value, 2)}$unit"

@Composable
private fun ThemeCard(label: String, theme: ReaderTheme, bg: Color, fg: Color, current: ReaderTheme, onSelect: (ReaderTheme) -> Unit) {
    val palette = Hearth.palette
    val selected = theme == current
    Column(
        modifier = Modifier.selectable(selected = selected, role = Role.RadioButton) { onSelect(theme) },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            Modifier.size(width = 56.dp, height = 72.dp).clip(RoundedCornerShape(10.dp)).background(bg)
                .border(if (selected) 2.dp else 1.dp, if (selected) palette.ember else palette.hairline, RoundedCornerShape(10.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Text("Aa", style = hearthDisplay(20.sp, FontWeight.SemiBold), color = fg)
        }
        Text(label, style = HearthText.Overline, color = if (selected) palette.ember else palette.textSecondary)
    }
}

@Composable
private fun Stepper(label: String, value: String, onDec: () -> Unit, onInc: () -> Unit) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = HearthText.Body, color = palette.text)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.L)) {
            StepperButton("-", "Decrease $label", onDec)
            Text(value, style = HearthText.Caption, color = palette.textSecondary)
            StepperButton("+", "Increase $label", onInc)
        }
    }
}

@Composable
private fun StepperButton(symbol: String, description: String, onClick: () -> Unit) {
    Text(
        symbol,
        style = HearthText.Body.copy(fontWeight = FontWeight.Bold, fontSize = 22.sp),
        color = Hearth.palette.ember,
        modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp).clip(CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description }
            .wrapContentSize(),
    )
}

@Composable
private fun ContentsSheet(vm: ReaderViewModel, state: ReaderUiState) {
    val palette = Hearth.palette
    var tab by remember { mutableIntStateOf(0) }
    var query by remember { mutableStateOf("") }
    val normalizedQuery = query.trim().lowercase()
    val filteredBookmarks = remember(state.bookmarks, normalizedQuery) {
        state.bookmarks.filter { it.matchesAnnotationQuery(normalizedQuery) }
    }
    val filteredNotes = remember(state.annotations, normalizedQuery) {
        state.annotations
            .filter { AnnotationKind.parse(it.kind) != AnnotationKind.BOOKMARK }
            .filter { it.matchesAnnotationQuery(normalizedQuery) }
    }
    val tocListState = rememberLazyListState()
    LaunchedEffect(tab, state.currentTocEntryId, state.tocEntries) {
        if (tab == 0) {
            val index = state.tocEntries.indexOfFirst { it.id == state.currentTocEntryId }
            if (index >= 0) tocListState.scrollToItem(index)
        }
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(bottom = Hearth.Spacing.XXL)) {
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XL), modifier = Modifier.padding(bottom = Hearth.Spacing.M)) {
            listOf("Contents", "Bookmarks", "Notes").forEachIndexed { i, label ->
                HearthChip(label, selected = i == tab, onClick = { tab = i })
            }
        }
        if (tab != 0) {
            SearchField(
                value = query,
                placeholder = if (tab == 1) "Search bookmarks..." else "Search notes...",
                onValueChange = { query = it },
            )
            Spacer(Modifier.size(Hearth.Spacing.S))
        }
        if (tab == 0 && state.tocPageCounts.values.any { it.estimated }) {
            Text(
                "Estimated chapter lengths; screen page counts may differ.",
                style = HearthText.Caption,
                color = palette.textSecondary,
                modifier = Modifier.padding(bottom = Hearth.Spacing.S),
            )
        }
        LazyColumn(Modifier.heightIn(max = 460.dp), state = tocListState) {
            when (tab) {
                0 -> if (state.tocEntries.isEmpty()) {
                    item { Empty("This book keeps no table of contents.") }
                } else {
                    items(state.tocEntries, key = { it.id }) { e ->
                        Column(
                            Modifier.fillMaxWidth().clickable { vm.navigateTo(e); vm.showToc(false) }
                                .padding(start = (e.depth * 16).dp, top = Hearth.Spacing.M, bottom = Hearth.Spacing.M),
                        ) {
                            Text(
                                e.title,
                                style = hearthDisplay(16.sp, FontWeight.Normal),
                                color = if (e.id == state.currentTocEntryId) palette.ember else palette.text,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                            state.tocPageCounts[e.id]?.let { count ->
                                val label = if (count.pages == 1) "1 page" else "${count.pages} pages"
                                Text(
                                    if (count.estimated) "~$label" else label,
                                    style = HearthText.Caption,
                                    color = palette.textSecondary,
                                    modifier = Modifier.semantics {
                                        contentDescription = if (count.estimated) "About $label" else label
                                    },
                                )
                            }
                        }
                    }
                }
                1 -> if (filteredBookmarks.isEmpty()) {
                    item { Empty(if (query.isBlank()) "Nothing marked yet." else "No bookmarks match that search.") }
                } else {
                    items(filteredBookmarks, key = { it.id }) { a ->
                        AnnotationRow(
                            a = a,
                            dot = palette.ember,
                            onOpen = { vm.seekToAnnotation(a); vm.showToc(false) },
                            onEdit = { vm.showDecorationPopover(a.id); vm.showToc(false) },
                            onDelete = { vm.deleteAnnotation(a) },
                        )
                    }
                }
                2 -> if (filteredNotes.isEmpty()) {
                    item { Empty(if (query.isBlank()) "No notes or highlights yet." else "No notes match that search.") }
                } else {
                    items(filteredNotes, key = { it.id }) { a ->
                        AnnotationRow(
                            a = a,
                            dot = highlightColorHex(a.colorHex)?.let(::parseHexColor) ?: EmberAccent,
                            onOpen = { vm.seekToAnnotation(a); vm.showToc(false) },
                            onEdit = { vm.showDecorationPopover(a.id); vm.showToc(false) },
                            onDelete = { vm.deleteAnnotation(a) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchField(value: String, placeholder: String, onValueChange: (String) -> Unit) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    Box(Modifier.fillMaxWidth().clip(shape).background(palette.bg).border(1.dp, palette.hairline, shape).padding(Hearth.Spacing.M)) {
        if (value.isEmpty()) Text(placeholder, style = HearthText.Body, color = palette.textTertiary)
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = HearthText.Body.copy(color = palette.text),
            cursorBrush = SolidColor(palette.ember),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun AnnotationRow(a: ReaderAnnotation, dot: Color, onOpen: () -> Unit, onEdit: () -> Unit, onDelete: () -> Unit) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(vertical = Hearth.Spacing.M), verticalAlignment = Alignment.Top) {
        Box(Modifier.size(10.dp).clip(CircleShape).background(dot).padding(top = 4.dp))
        Spacer(Modifier.size(Hearth.Spacing.M))
        Column(Modifier.weight(1f)) {
            Text(a.selectedText.ifBlank { a.note.ifBlank { "Bookmark" } }, style = HearthText.Body, color = palette.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
            if (a.note.isNotBlank() && a.selectedText.isNotBlank()) Text(a.note, style = HearthText.Caption, color = palette.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Text("Edit", style = HearthText.Caption, color = palette.ember, modifier = Modifier.sizeIn(minHeight = 48.dp).clip(RoundedCornerShape(50)).clickable(role = Role.Button, onClick = onEdit).wrapContentHeight().padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.XS))
        Icon(Icons.Outlined.Delete, "Delete", tint = palette.textTertiary, modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp).clip(CircleShape).clickable(role = Role.Button, onClick = onDelete).wrapContentSize().size(18.dp))
    }
}

private fun ReaderAnnotation.matchesAnnotationQuery(query: String): Boolean {
    if (query.isBlank()) return true
    return selectedText.contains(query, ignoreCase = true) ||
        note.contains(query, ignoreCase = true) ||
        chapterId.orEmpty().contains(query, ignoreCase = true) ||
        style.contains(query, ignoreCase = true) ||
        colorHex.contains(query, ignoreCase = true)
}

@Composable
private fun SearchSheet(vm: ReaderViewModel, state: ReaderUiState) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) {
        if (state.searchQuery.isEmpty()) {
            focus.requestFocus()
            keyboard?.show()
        }
    }
    Column(Modifier.fillMaxWidth().imePadding().padding(horizontal = Hearth.Spacing.XL).padding(bottom = Hearth.Spacing.XXL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Overline("Search book")
            Spacer(Modifier.weight(1f))
            IconButton(onClick = {
                if (state.searchLoading) vm.cancelSearch() else { vm.runSearch(); keyboard?.hide() }
            }) {
                Icon(
                    if (state.searchLoading) Icons.Outlined.Close else Icons.Outlined.Search,
                    contentDescription = if (state.searchLoading) "Cancel search" else "Search",
                    tint = palette.ember,
                )
            }
            IconButton(onClick = { vm.showSearch(false) }) {
                Icon(Icons.Outlined.Close, contentDescription = "Close search", tint = palette.textSecondary)
            }
        }
        Box(Modifier.fillMaxWidth().clip(shape).background(palette.bg).border(1.dp, palette.hairline, shape).padding(Hearth.Spacing.M)) {
            if (state.searchQuery.isEmpty()) Text("Find in this book…", style = hearthDisplay(16.sp, FontWeight.Normal), color = palette.textTertiary)
            BasicTextField(
                value = state.searchQuery, onValueChange = vm::updateSearchQuery, singleLine = true,
                textStyle = hearthDisplay(16.sp, FontWeight.Normal).copy(color = palette.text),
                cursorBrush = SolidColor(palette.ember),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = { vm.runSearch(); keyboard?.hide() }),
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Search),
                modifier = Modifier.fillMaxWidth().focusRequester(focus).semantics { contentDescription = "Search text" },
            )
        }
        if (state.searchOptionsAvailable) {
            HearthToggleRow("Whole words", state.searchWholeWords, vm::updateSearchWholeWords)
            Text(
                if (state.searchWholeWords) "Word or exact phrase. Matching headings appear first."
                else "Includes partial words. Large books may take longer.",
                style = HearthText.Caption,
                color = palette.textSecondary,
            )
        }
        state.searchStatus?.let { Text(it, style = HearthText.Caption, color = palette.textSecondary) }
        state.searchError?.let { Text(it, style = HearthText.Caption, color = palette.statusError) }
        LazyColumn(Modifier.heightIn(max = 400.dp).weight(1f, fill = false)) {
            items(state.searchResults, key = { it.id }) { r ->
                Column(
                    Modifier.fillMaxWidth().clickable { vm.seekToSearchResult(r); vm.showSearch(false) }.padding(vertical = Hearth.Spacing.M),
                ) {
                    Overline(r.title)
                    val text = r.locator.text
                    val emphasized = androidx.compose.ui.text.buildAnnotatedString {
                        append(text.before.orEmpty().replace(Regex("\\s+"), " ").takeLast(70))
                        withStyle(SpanStyle(color = palette.ember, fontWeight = FontWeight.SemiBold)) {
                            append(text.highlight.orEmpty().replace(Regex("\\s+"), " "))
                        }
                        append(text.after.orEmpty().replace(Regex("\\s+"), " ").take(90))
                    }
                    Text(emphasized, style = HearthText.Body, color = palette.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
            }
            if (state.searchHasMore && !state.searchLoading) {
                item {
                    HearthChip("Load more results", selected = false, onClick = vm::loadMoreSearchResults)
                }
            }
        }
    }
}

@Composable
private fun Empty(text: String) {
    Text(text, style = HearthText.Body, color = Hearth.palette.textSecondary, modifier = Modifier.padding(vertical = Hearth.Spacing.L))
}
