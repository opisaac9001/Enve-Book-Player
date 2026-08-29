package com.enve.hearth.storyalign

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Headphones
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.engine.storyalign.StoryAlignJobUi
import com.enve.engine.storyalign.StoryAlignStatus
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.hearthDisplay

@Composable
fun HearthStoryAlignScreen(
    onBack: () -> Unit,
    vm: HearthStoryAlignViewModel = hiltViewModel(),
) {
    val palette = Hearth.palette
    val picking by vm.picking.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxSize().background(palette.bg)) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.AutoMirrored.Outlined.ArrowBack, "Back", tint = palette.text,
                modifier = Modifier.clip(CircleShape)
                    .clickable { if (picking != null) vm.closePicker() else onBack() }
                    .padding(Hearth.Spacing.S).size(26.dp),
            )
            Spacer(Modifier.size(Hearth.Spacing.S))
            Column {
                Overline(if (picking == PickTarget.EBOOK) "Choose the ebook" else if (picking == PickTarget.AUDIOBOOK) "Choose the audiobook" else "Library & content")
                Text("StoryAlign", style = HearthText.ScreenTitle, color = palette.text)
            }
        }

        if (picking != null) {
            PickerView(vm)
        } else {
            MainView(vm)
        }
    }
}

@Composable
private fun MainView(vm: HearthStoryAlignViewModel) {
    val palette = Hearth.palette
    val ebook by vm.selectedEbook.collectAsStateWithLifecycle()
    val audiobook by vm.selectedAudiobook.collectAsStateWithLifecycle()
    val canStart by vm.canStart.collectAsStateWithLifecycle()
    val jobs by vm.jobs.collectAsStateWithLifecycle()
    var showModelTerms by remember { mutableStateOf(false) }

    if (showModelTerms) {
        AlertDialog(
            onDismissRequest = { showModelTerms = false },
            confirmButton = {
                TextButton(
                    onClick = {
                        showModelTerms = false
                        vm.startAlignment()
                    },
                ) { Text("Continue", color = palette.ember) }
            },
            dismissButton = {
                TextButton(onClick = { showModelTerms = false }) {
                    Text("Cancel", color = palette.textSecondary)
                }
            },
            title = { Text("On-device transcription model", color = palette.text) },
            text = {
                Text(
                    "StoryAlign uses the 74 MB Whisper tiny.en model under the MIT license. " +
                        "Enve downloads the pinned model if it is not installed, verifies its SHA-256 digest, and performs transcription on this device. " +
                        "The full notice is available in About → Open-source licenses.",
                    color = palette.textSecondary,
                )
            },
            containerColor = palette.bgElevated,
        )
    }

    LazyColumn(
        contentPadding = PaddingValues(
            start = Hearth.Spacing.XL, end = Hearth.Spacing.XL,
            top = Hearth.Spacing.S, bottom = LocalMantelInset.current + Hearth.Spacing.XL,
        ),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXL),
    ) {
        item {
            Text(
                "Make read-aloud EPUBs: synced text, audio, and live highlighting.",
                style = HearthText.Body, color = palette.textSecondary,
            )
        }

        item {
            Card {
                Overline("The pair")
                Row(
                    Modifier.fillMaxWidth().padding(top = Hearth.Spacing.M),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    PairSlot(
                        icon = Icons.AutoMirrored.Outlined.MenuBook,
                        label = "Ebook",
                        chosen = ebook?.title,
                        modifier = Modifier.weight(1f),
                    ) { vm.openPicker(PickTarget.EBOOK) }
                    Icon(
                        Icons.Outlined.SwapHoriz, contentDescription = null, tint = palette.textTertiary,
                        modifier = Modifier.padding(horizontal = Hearth.Spacing.S).size(22.dp),
                    )
                    PairSlot(
                        icon = Icons.Outlined.Headphones,
                        label = "Audiobook",
                        chosen = audiobook?.title,
                        modifier = Modifier.weight(1f),
                    ) { vm.openPicker(PickTarget.AUDIOBOOK) }
                }
                Spacer(Modifier.height(Hearth.Spacing.L))
                Text(
                    "Pick both halves of one story. Enve downloads anything missing, aligns them, and shelves the read-aloud EPUB in your library.",
                    style = HearthText.Body, color = palette.textSecondary,
                )
                Spacer(Modifier.height(Hearth.Spacing.L))
                StartButton(enabled = canStart) { showModelTerms = true }
            }
        }

        item {
            Card {
                Overline("How it works")
                Spacer(Modifier.height(Hearth.Spacing.M))
                Text(
                    "StoryAlign transcribes the audiobook on-device (whisper) and lines each " +
                        "sentence up with the ebook text, writing the result as media overlays " +
                        "inside a new EPUB. Open it from your library to read and listen at once, " +
                        "sentences lighting up as they're spoken. Everything stays on this device.",
                    style = HearthText.Body, color = palette.textSecondary,
                )
            }
        }

        if (jobs.isNotEmpty()) {
            item {
                Card {
                    Overline("Generation jobs")
                    Spacer(Modifier.height(Hearth.Spacing.M))
                    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L)) {
                        jobs.forEach { job ->
                            JobRow(job, onCancel = { vm.cancel(job.id) }, onRetry = { vm.retry(job.id) }, onDelete = { vm.delete(job.id) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PickerView(vm: HearthStoryAlignViewModel) {
    val palette = Hearth.palette
    val query by vm.pickQuery.collectAsStateWithLifecycle()
    val results by vm.pickResults.collectAsStateWithLifecycle()
    val picking by vm.picking.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxSize().padding(horizontal = Hearth.Spacing.XL)) {
        SearchField(query, vm::setQuery, if (picking == PickTarget.EBOOK) "Find an ebook…" else "Find an audiobook…")
        Spacer(Modifier.height(Hearth.Spacing.M))
        if (results.isEmpty()) {
            Text(
                if (query.isBlank()) "Nothing to show yet." else "No matches for \"$query\".",
                style = HearthText.Body, color = palette.textSecondary,
            )
        } else {
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
                contentPadding = PaddingValues(bottom = LocalMantelInset.current + Hearth.Spacing.XL),
            ) {
                items(results) { book ->
                    BookPickRow(book) { vm.choose(book) }
                }
            }
        }
    }
}

@Composable
private fun PairSlot(icon: ImageVector, label: String, chosen: String?, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val palette = Hearth.palette
    val radius = 16.dp
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier.fillMaxWidth().height(120.dp)
                .clip(RoundedCornerShape(radius))
                .dashedBorder(if (chosen != null) palette.ember else palette.hairline, radius)
                .clickable(onClick = onClick),
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                Icon(icon, contentDescription = null, tint = palette.ember, modifier = Modifier.size(30.dp))
                Text(label, style = HearthText.Label, color = palette.text)
            }
        }
        Spacer(Modifier.height(Hearth.Spacing.S))
        Text(
            chosen ?: "Tap to choose",
            style = HearthText.Caption,
            color = if (chosen != null) palette.text else palette.textTertiary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun StartButton(enabled: Boolean, onClick: () -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(Hearth.Radius.Bar))
            .background(palette.ember)
            .alpha(if (enabled) 1f else 0.45f)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = Hearth.Spacing.L),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.AutoAwesome, contentDescription = null, tint = palette.readableOnEmber, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(Hearth.Spacing.S))
        Text("Start alignment", style = HearthText.Label, color = palette.readableOnEmber)
    }
}

@Composable
private fun BookPickRow(book: Book, onPick: () -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Inner)).background(palette.bgElevated)
            .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Inner))
            .clickable(onClick = onPick)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.M),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(book.title, style = HearthText.Label, color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val author = book.author
            if (!author.isNullOrBlank()) {
                Text(author, style = HearthText.Caption, color = palette.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun SearchField(query: String, onQuery: (String) -> Unit, placeholder: String) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(palette.bgElevated).border(1.dp, palette.hairline, shape)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.M),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.Search, contentDescription = null, tint = palette.textTertiary, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(Hearth.Spacing.S))
        Box(Modifier.weight(1f)) {
            if (query.isEmpty()) {
                Text(placeholder, style = hearthDisplay(16.sp, FontWeight.Normal), color = palette.textTertiary)
            }
            BasicTextField(
                value = query,
                onValueChange = onQuery,
                singleLine = true,
                textStyle = hearthDisplay(16.sp, FontWeight.Normal).copy(color = palette.text),
                cursorBrush = SolidColor(palette.ember),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (query.isNotEmpty()) {
            Icon(
                Icons.Outlined.Close, "Clear", tint = palette.textTertiary,
                modifier = Modifier.clip(CircleShape).clickable { onQuery("") }.size(20.dp),
            )
        }
    }
}

@Composable
private fun JobRow(job: StoryAlignJobUi, onCancel: () -> Unit, onRetry: () -> Unit, onDelete: () -> Unit) {
    val palette = Hearth.palette
    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        Text(job.ebookTitle, style = HearthText.Label, color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(job.statusLine(), style = HearthText.Caption, color = job.statusColor(), maxLines = 2, overflow = TextOverflow.Ellipsis)
        if (job.isActive) {
            LinearProgressIndicator(
                progress = { job.overallProgress },
                modifier = Modifier.fillMaxWidth(),
                color = palette.ember,
                trackColor = palette.hairline,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            if (job.isActive) {
                HearthChip("Cancel", selected = false, onClick = onCancel)
            } else if (job.status == StoryAlignStatus.FAILED || job.status == StoryAlignStatus.CANCELLED) {
                HearthChip("Retry", selected = true, onClick = onRetry)
            }
            HearthChip("Delete", selected = false, onClick = onDelete)
        }
    }
}

private fun StoryAlignJobUi.statusLine(): String = when (status) {
    StoryAlignStatus.QUEUED -> "Queued"
    StoryAlignStatus.RUNNING -> "${stage.label()} · ${(overallProgress * 100).toInt()}%"
    StoryAlignStatus.PAUSED -> "Paused · ${stage.label()}"
    StoryAlignStatus.DONE -> "Ready to read"
    StoryAlignStatus.CANCELLED -> "Cancelled"
    StoryAlignStatus.FAILED -> errorMessage ?: "Failed"
}

@Composable
private fun StoryAlignJobUi.statusColor() = when (status) {
    StoryAlignStatus.DONE -> Hearth.palette.statusOK
    StoryAlignStatus.FAILED -> Hearth.palette.statusError
    else -> Hearth.palette.textSecondary
}

private fun com.enve.engine.storyalign.StoryAlignStage.label(): String = when (this) {
    com.enve.engine.storyalign.StoryAlignStage.DOWNLOAD -> "Downloading"
    com.enve.engine.storyalign.StoryAlignStage.EPUB_PARSE -> "Reading ebook"
    com.enve.engine.storyalign.StoryAlignStage.AUDIO_EXTRACT -> "Preparing audio"
    com.enve.engine.storyalign.StoryAlignStage.TRANSCRIBE -> "Transcribing"
    com.enve.engine.storyalign.StoryAlignStage.ALIGN -> "Aligning"
    com.enve.engine.storyalign.StoryAlignStage.EXPORT -> "Building book"
    com.enve.engine.storyalign.StoryAlignStage.REGISTER -> "Finishing"
}

@Composable
private fun Card(content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    val palette = Hearth.palette
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Card)).background(palette.bgElevated)
            .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card)).padding(Hearth.Spacing.L),
        content = content,
    )
}

private fun Modifier.dashedBorder(color: Color, radius: androidx.compose.ui.unit.Dp): Modifier = drawBehind {
    drawRoundRect(
        color = color,
        cornerRadius = CornerRadius(radius.toPx()),
        style = Stroke(width = 1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(16f, 12f), 0f)),
    )
}
