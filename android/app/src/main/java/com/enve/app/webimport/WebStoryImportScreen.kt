package com.enve.app.webimport

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.enve.app.ui.webbrowser.WebStoryBrowser
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.ScreenHeader
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.hearthUI
import java.io.File

@Composable
fun WebStoryImportScreen(onBack: () -> Unit, onImport: suspend (File) -> Unit) {
    val viewModel: WebStoryImportViewModel = viewModel()
    val state by viewModel.state.collectAsStateWithLifecycle()
    val currentOnImport by rememberUpdatedState(onImport)
    val commit = remember<suspend (File) -> Unit> { { file -> currentOnImport(file) } }
    var input by rememberSaveable { mutableStateOf("") }
    var browserUrl by rememberSaveable { mutableStateOf<String?>(null) }

    browserUrl?.let { url ->
        WebStoryBrowser(
            initialUrl = url,
            onClose = { browserUrl = null },
            onCapture = { capturedUrl, html ->
                browserUrl = null
                viewModel.previewCaptured(capturedUrl, html)
            },
        )
        return
    }

    val palette = Hearth.palette
    Column(
        Modifier
            .fillMaxSize()
            .background(palette.bg)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(bottom = Hearth.Spacing.XL),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
    ) {
        ScreenHeader(
            title = "Import from link",
            overline = "Web story",
            trailing = { CloseButton(onBack) },
        )
        Column(
            Modifier.padding(horizontal = Hearth.Spacing.XL),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
        ) {
            val current = state
            val editable = current is WebStoryImportUiState.Entry || current is WebStoryImportUiState.Ready
            val validUrl = remember(input) { runCatching { WebStoryUrls.parseInput(input) }.getOrNull() }
            UrlField(
                value = input,
                enabled = editable,
                onValueChange = { input = it },
                onSubmit = { if (validUrl != null) viewModel.preview(input) },
            )
            if (editable) {
                EntryActions(
                    canUse = validUrl != null,
                    onPreview = { viewModel.preview(input) },
                    onOpenInBrowser = { validUrl?.let { browserUrl = it.toString() } },
                )
            }
            when (current) {
                is WebStoryImportUiState.Entry -> {
                    current.error?.let { ErrorText(it) }
                    Text(
                        "Paste a web article, a Royal Road story or a direct ebook link. Use Open in browser for pages " +
                            "that need sign-in or a verification step, then import the page you're viewing.",
                        style = HearthText.Caption,
                        color = palette.textSecondary,
                    )
                }
                WebStoryImportUiState.Loading -> WorkingContent("Reading the page", null, onCancel = viewModel::cancel)
                is WebStoryImportUiState.Ready -> ReadyContent(current) { scope -> viewModel.import(scope, commit) }
                is WebStoryImportUiState.Importing -> WorkingContent(
                    title = "Importing ${current.preview.metadata.title}",
                    progress = current.progress,
                    onCancel = viewModel::cancel,
                )
                is WebStoryImportUiState.Saving -> WorkingContent("Adding ${current.title} to the library", null, onCancel = null)
                is WebStoryImportUiState.Saved -> SavedContent(
                    state = current,
                    onDone = onBack,
                    onImportAnother = {
                        input = ""
                        viewModel.startOver()
                    },
                )
            }
        }
    }
}

@Composable
private fun CloseButton(onBack: () -> Unit) {
    Icon(
        Icons.Default.Close,
        contentDescription = "Close web import",
        tint = Hearth.palette.textSecondary,
        modifier = Modifier
            .clip(if (Hearth.eink.sharpCorners) RectangleShape else CircleShape)
            .clickable(role = Role.Button, onClick = onBack)
            .padding(12.dp)
            .size(24.dp),
    )
}

@Composable
private fun UrlField(value: String, enabled: Boolean, onValueChange: (String) -> Unit, onSubmit: () -> Unit) {
    val palette = Hearth.palette
    val shape = cardShape()
    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        Overline("Web address")
        Box(
            Modifier
                .fillMaxWidth()
                .alpha(if (enabled || Hearth.eink.active) 1f else 0.6f)
                .clip(shape)
                .background(palette.bgElevated)
                .border(1.dp, palette.hairline, shape)
                .padding(horizontal = 14.dp, vertical = 13.dp),
            contentAlignment = Alignment.CenterStart,
        ) {
            if (value.isEmpty()) {
                Text("https://", style = hearthUI(15.sp), color = palette.textTertiary)
            }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                enabled = enabled,
                singleLine = true,
                textStyle = hearthUI(15.sp).copy(color = palette.text),
                cursorBrush = SolidColor(palette.ember),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    imeAction = ImeAction.Go,
                    autoCorrectEnabled = false,
                ),
                keyboardActions = KeyboardActions(onGo = { onSubmit() }),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun EntryActions(canUse: Boolean, onPreview: () -> Unit, onOpenInBrowser: () -> Unit) {
    val dimmed = Modifier.alpha(if (canUse || Hearth.eink.active) 1f else 0.4f)
    EmberButton("Preview", onClick = { if (canUse) onPreview() }, modifier = dimmed.fillMaxWidth())
    QuietButton("Open in browser", onClick = { if (canUse) onOpenInBrowser() }, modifier = dimmed.fillMaxWidth())
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ReadyContent(state: WebStoryImportUiState.Ready, onImport: (WebStoryScope) -> Unit) {
    val palette = Hearth.palette
    val preview = state.preview
    val serial = preview as? WebStoryPreview.Serial
    var scope by rememberSaveable(preview) {
        mutableStateOf(serial?.defaultScope ?: WebStoryScope.WHOLE_STORY)
    }

    Card {
        Overline(
            when (preview) {
                is WebStoryPreview.Serial -> "${preview.chapters.size} chapters · ${preview.metadata.sourceUrl.host}"
                is WebStoryPreview.Download -> "${preview.format.extension.uppercase()} file · ${preview.metadata.sourceUrl.host}"
                is WebStoryPreview.Page -> preview.metadata.sourceUrl.host
            },
            color = palette.ember,
        )
        Text(
            preview.metadata.title,
            style = hearthDisplay(19.sp, FontWeight.SemiBold),
            color = palette.text,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        preview.metadata.author?.let {
            Text(it, style = hearthUI(13.sp), color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        preview.metadata.description?.let {
            Text(it, style = hearthUI(13.sp), color = palette.textSecondary, maxLines = 6, overflow = TextOverflow.Ellipsis)
        }
    }

    if (serial != null) {
        Card {
            Overline("Import")
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                serial.scopes.forEach { option ->
                    HearthChip(label = option.label(), selected = option == scope, onClick = { scope = option })
                }
            }
            val indices = serial.indices(scope)
            Text(
                if (indices.first == indices.last) {
                    serial.chapters[indices.first].title
                } else {
                    "${serial.chapters[indices.first].title} → ${serial.chapters[indices.last].title}"
                },
                style = HearthText.Caption,
                color = palette.textSecondary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }

    state.error?.let { ErrorText(it) }
    val label = when (preview) {
        is WebStoryPreview.Serial -> {
            val indices = preview.indices(scope)
            val count = indices.last - indices.first + 1
            if (count == 1) "Import 1 chapter" else "Import $count chapters"
        }
        is WebStoryPreview.Download -> "Add file to library"
        is WebStoryPreview.Page -> "Import page"
    }
    EmberButton(label, onClick = { onImport(scope) }, modifier = Modifier.fillMaxWidth())
    Text(
        "Imports are snapshots. Images are kept as their descriptions, and a missing or blocked chapter stops the import.",
        style = HearthText.Caption,
        color = palette.textSecondary,
    )
}

private fun WebStoryScope.label() = when (this) {
    WebStoryScope.THIS_CHAPTER -> "This chapter"
    WebStoryScope.FROM_HERE -> "From here"
    WebStoryScope.WHOLE_STORY -> "Whole story"
}

@Composable
private fun WorkingContent(title: String, progress: WebStoryImportProgress?, onCancel: (() -> Unit)?) {
    val palette = Hearth.palette
    Card {
        Text(title, style = hearthUI(15.sp, FontWeight.SemiBold), color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
        progress?.let {
            Text("${it.completed} of ${it.total}", style = HearthText.Caption, color = palette.textSecondary)
        }
        when {
            progress != null && progress.total > 0 -> LinearProgressIndicator(
                progress = { progress.completed.toFloat() / progress.total },
                color = palette.ember,
                trackColor = palette.hairline,
                modifier = Modifier.fillMaxWidth(),
            )
            !Hearth.eink.suppressAnimations -> LinearProgressIndicator(
                color = palette.ember,
                trackColor = palette.hairline,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
    onCancel?.let { QuietButton("Cancel", onClick = it, modifier = Modifier.fillMaxWidth()) }
}

@Composable
private fun SavedContent(state: WebStoryImportUiState.Saved, onDone: () -> Unit, onImportAnother: () -> Unit) {
    val palette = Hearth.palette
    Card {
        Overline("Added to the library", color = palette.ember)
        Text(state.title, style = hearthDisplay(19.sp, FontWeight.SemiBold), color = palette.text)
        if (state.chapters > 0) {
            Text(
                if (state.chapters == 1) "1 chapter" else "${state.chapters} chapters",
                style = HearthText.Caption,
                color = palette.textSecondary,
            )
        }
    }
    EmberButton("Done", onClick = onDone, modifier = Modifier.fillMaxWidth())
    QuietButton("Import another", onClick = onImportAnother, modifier = Modifier.fillMaxWidth())
}

@Composable
private fun ErrorText(message: String) {
    Text(message, style = HearthText.Caption, color = Hearth.palette.statusError)
}

@Composable
private fun Card(content: @Composable ColumnScope.() -> Unit) {
    val palette = Hearth.palette
    val shape = cardShape()
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        content = content,
    )
}

@Composable
private fun cardShape(): Shape = if (Hearth.eink.sharpCorners) RectangleShape else RoundedCornerShape(Hearth.Radius.Inner)
