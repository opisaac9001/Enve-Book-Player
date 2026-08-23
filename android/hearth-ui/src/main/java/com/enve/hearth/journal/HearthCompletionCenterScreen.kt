package com.enve.hearth.journal

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthFormat
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.ShelfHeader

@Composable
fun HearthCompletionCenterScreen(
    onBack: () -> Unit,
    onSelectBook: (Book) -> Unit,
) {
    val vm: HearthJournalViewModel = hiltViewModel()
    val almostFinished by vm.almostFinished.collectAsStateWithLifecycle()
    val recentlyFinished by vm.finished.collectAsStateWithLifecycle()
    val palette = Hearth.palette

    Column(Modifier.fillMaxSize().background(palette.bg)) {
        Row(
            Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onBack),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Outlined.ArrowBack,
                    contentDescription = "Back",
                    tint = palette.text,
                    modifier = Modifier.size(26.dp),
                )
            }
            Spacer(Modifier.size(Hearth.Spacing.S))
            Column(Modifier.weight(1f)) {
                Overline("Reading milestones")
                Text("Finish Line", style = HearthText.ScreenTitle, color = palette.text)
            }
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = Hearth.Spacing.XXL),
        ) {
            if (almostFinished.isNotEmpty()) {
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                        ShelfHeader(
                            "Almost Finished",
                            modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL),
                        )
                        LazyRow(
                            contentPadding = PaddingValues(horizontal = Hearth.Spacing.XL),
                            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
                        ) {
                            items(almostFinished, key = { it.uniqueKey }) { book ->
                                CompletionCoverCard(book, onSelectBook)
                            }
                        }
                    }
                }
            }

            if (almostFinished.isNotEmpty() && recentlyFinished.isNotEmpty()) {
                item { Spacer(Modifier.height(Hearth.Spacing.XXL)) }
            }

            if (recentlyFinished.isNotEmpty()) {
                item {
                    ShelfHeader(
                        "Recently Finished",
                        modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL),
                    )
                }
                items(recentlyFinished, key = { it.uniqueKey }) { book ->
                    CompletionHistoryRow(
                        book,
                        onSelectBook,
                        modifier = Modifier.padding(horizontal = Hearth.Spacing.XL),
                    )
                }
            }

            if (almostFinished.isEmpty() && recentlyFinished.isEmpty()) {
                item {
                    Text(
                        "Books nearing the end, and every finish after them, will gather here.",
                        style = HearthText.Body,
                        color = palette.textSecondary,
                        modifier = Modifier.padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.XXL),
                    )
                }
            }
        }
    }
}

@Composable
private fun CompletionCoverCard(book: Book, onSelectBook: (Book) -> Unit) {
    val palette = Hearth.palette
    val progress = CompletionCenterPolicy.progress(book)
    Column(
        Modifier.width(118.dp).clickable { onSelectBook(book) },
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        CoverTile(
            model = book.coverUrl,
            contentDescription = book.title,
            progress = progress,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            book.title,
            style = HearthText.Label,
            color = palette.text,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            HearthFormat.timeLeft(book) ?: "${(progress * 100).toInt()}% complete",
            style = HearthText.Caption,
            color = palette.textSecondary,
            maxLines = 1,
        )
    }
}

@Composable
private fun CompletionHistoryRow(
    book: Book,
    onSelectBook: (Book) -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    Row(
        modifier
            .fillMaxWidth()
            .clickable { onSelectBook(book) }
            .padding(vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        CoverTile(
            model = book.coverUrl,
            contentDescription = book.title,
            isFinished = true,
            modifier = Modifier.width(54.dp),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
            Text(
                book.title,
                style = HearthText.Label,
                color = palette.text,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                book.author?.trim().takeUnless { it.isNullOrEmpty() } ?: book.mediaType.name.lowercase().replaceFirstChar(Char::uppercase),
                style = HearthText.Caption,
                color = palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            (HearthFormat.relativeAgo(book.lastReadTime) ?: "Finished").replaceFirstChar(Char::uppercase),
            style = HearthText.Caption,
            color = palette.textTertiary,
            maxLines = 1,
        )
    }
}
