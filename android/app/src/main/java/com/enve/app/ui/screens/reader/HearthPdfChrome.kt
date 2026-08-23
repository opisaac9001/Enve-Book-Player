package com.enve.app.ui.screens.reader

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.app.data.reader.ReaderTheme
import com.enve.app.ui.screens.PdfReaderUiState
import com.enve.core.data.model.Book
import com.enve.hearth.design.EmberAccent
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalHearth
import com.enve.hearth.design.LocalHearthEink
import com.enve.hearth.design.Overline

@Composable
internal fun HearthPdfChrome(
    state: PdfReaderUiState,
    einkActive: Boolean,
    onBack: () -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onSeekPage: (Int) -> Unit,
    onReadNext: (Book) -> Unit,
) {
    val palette = readerChromePalette(ReaderTheme.OLED, einkActive, EmberAccent)
    CompositionLocalProvider(
        LocalHearth provides palette,
        LocalHearthEink provides hearthEinkFor(palette, einkActive),
    ) {
        Box(Modifier.fillMaxSize().background(if (einkActive) Color.White else Color(0xFF111111))) {
            Column(Modifier.fillMaxSize()) {
                PdfTopVeil(state.title, state.author, onBack)
                Box(
                    Modifier.weight(1f).fillMaxWidth().padding(horizontal = Hearth.Spacing.L),
                    contentAlignment = Alignment.Center,
                ) {
                    val error = state.error
                    val bitmap = state.currentBitmap
                    when {
                        error != null -> Text(
                            error,
                            style = HearthText.Body,
                            color = palette.text,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.padding(Hearth.Spacing.XXL),
                        )
                        bitmap != null -> Image(
                            bitmap = bitmap.asImageBitmap(),
                            contentDescription = "PDF page ${state.currentPage + 1}",
                            modifier = Modifier.fillMaxSize(),
                            contentScale = ContentScale.Fit,
                        )
                        else -> Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
                        ) {
                            if (!einkActive) CircularProgressIndicator(color = palette.ember)
                            Text(state.loadingText, style = HearthText.Body, color = palette.textSecondary)
                        }
                    }
                }
                PdfBottomVeil(state, onPrevious, onNext, onSeekPage)
            }
            val nextBook = state.nextInSeries
            if (nextBook != null && state.pageCount > 0 && state.currentPage >= state.pageCount - 1) {
                HearthReadNextButton(
                    book = nextBook,
                    onClick = { onReadNext(nextBook) },
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = 96.dp, start = Hearth.Spacing.XL, end = Hearth.Spacing.XL),
                )
            }
        }
    }
}

@Composable
private fun PdfTopVeil(title: String, author: String, onBack: () -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    Column(Modifier.fillMaxWidth().background(palette.bg.copy(alpha = if (eink.active) 1f else 0.94f))) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding()
                .padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            VeilGlyph(Icons.AutoMirrored.Outlined.ArrowBack, "Back", palette.text, onBack)
            Spacer(Modifier.width(Hearth.Spacing.S))
            Column(Modifier.weight(1f)) {
                Overline(title)
                if (author.isNotBlank()) {
                    Text(
                        author,
                        style = HearthText.Caption,
                        color = palette.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        if (eink.active) Box(Modifier.fillMaxWidth().height(1.dp).background(palette.hairline))
    }
}

@Composable
private fun PdfBottomVeil(
    state: PdfReaderUiState,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onSeekPage: (Int) -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    var scrubTarget by remember { mutableStateOf<Int?>(null) }
    Column(Modifier.fillMaxWidth().background(palette.bg.copy(alpha = if (eink.active) 1f else 0.94f))) {
        if (eink.active) Box(Modifier.fillMaxWidth().height(1.dp).background(palette.hairline))
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding()
                .padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.M),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            if (state.pageCount > 0) {
                PageRibbon(
                    displayPage = scrubTarget ?: state.currentPage,
                    pageCount = state.pageCount,
                    onScrub = { scrubTarget = it },
                    onCommit = { scrubTarget = null; onSeekPage(it) },
                )
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                VeilGlyph(Icons.Filled.ChevronLeft, "Previous page", palette.text, onPrevious, enabled = state.currentPage > 0)
                val target = scrubTarget
                Text(
                    when {
                        state.pageCount <= 0 -> "Preparing…"
                        target != null -> "Page ${target + 1} of ${state.pageCount}"
                        else -> "Page ${state.currentPage + 1} of ${state.pageCount}"
                    },
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f),
                )
                VeilGlyph(Icons.Filled.ChevronRight, "Next page", palette.text, onNext, enabled = state.currentPage < state.pageCount - 1)
            }
            if (state.isLoading && state.loadingProgress != null) {
                Text(
                    "${state.loadingProgress}%",
                    style = HearthText.Caption,
                    color = palette.textTertiary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}
