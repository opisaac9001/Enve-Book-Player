package com.enve.hearth.detail

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.engine.library.LibraryLinkCandidate
import com.enve.engine.library.AudiobookshelfHistoryCandidate
import com.enve.engine.library.LibraryMetadataEdit
import com.enve.engine.library.LibraryMetadataMatch
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText

@Composable
internal fun MetadataEditDialog(
    book: Book,
    onDismiss: () -> Unit,
    onSave: (LibraryMetadataEdit) -> Unit,
) {
    var title by remember(book.id) { mutableStateOf(book.title) }
    var subtitle by remember(book.id) { mutableStateOf(book.subtitle.orEmpty()) }
    var author by remember(book.id) { mutableStateOf(book.author.orEmpty()) }
    var narrator by remember(book.id) { mutableStateOf(book.narrator.orEmpty()) }
    var seriesName by remember(book.id) { mutableStateOf(book.seriesName.orEmpty()) }
    var seriesNumber by remember(book.id) { mutableStateOf(book.seriesNumber.orEmpty()) }
    var publisher by remember(book.id) { mutableStateOf(book.publisher.orEmpty()) }
    var publishedDate by remember(book.id) { mutableStateOf(book.publishedDate.orEmpty()) }
    var isbn13 by remember(book.id) { mutableStateOf(book.isbn13.orEmpty()) }
    var language by remember(book.id) { mutableStateOf(book.language.orEmpty()) }
    var pageCount by remember(book.id) { mutableStateOf(book.pageCount?.toString().orEmpty()) }
    var categories by remember(book.id) { mutableStateOf(book.categories.joinToString(", ")) }
    var description by remember(book.id) { mutableStateOf(book.description.orEmpty()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Edit metadata") },
        text = {
            Column(
                Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                MetadataField("Title", title, { title = it })
                MetadataField("Subtitle", subtitle, { subtitle = it })
                MetadataField("Author", author, { author = it })
                MetadataField("Narrator", narrator, { narrator = it })
                MetadataField("Series", seriesName, { seriesName = it })
                MetadataField("Series #", seriesNumber, { seriesNumber = it })
                MetadataField("Publisher", publisher, { publisher = it })
                MetadataField("Published", publishedDate, { publishedDate = it })
                MetadataField("ISBN-13", isbn13, { isbn13 = it })
                MetadataField("Language", language, { language = it })
                MetadataField("Pages", pageCount, { pageCount = it })
                MetadataField("Categories", categories, { categories = it })
                MetadataField("Description", description, { description = it }, singleLine = false)
            }
        },
        confirmButton = {
            Button(onClick = {
                onSave(
                    LibraryMetadataEdit(
                        title = title.trim(),
                        subtitle = subtitle.blankToNull(),
                        author = author.blankToNull(),
                        narrator = narrator.blankToNull(),
                        description = description.blankToNull(),
                        seriesName = seriesName.blankToNull(),
                        seriesNumber = seriesNumber.blankToNull(),
                        publisher = publisher.blankToNull(),
                        publishedDate = publishedDate.blankToNull(),
                        isbn13 = isbn13.blankToNull(),
                        language = language.blankToNull(),
                        pageCount = pageCount.trim().toIntOrNull(),
                        categories = categories.split(",").mapNotNull { it.trim().takeIf(String::isNotBlank) },
                    )
                )
            }) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun MetadataField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    singleLine: Boolean = true,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = singleLine,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
internal fun MetadataMatchDialog(
    query: String,
    matches: List<LibraryMetadataMatch>,
    searching: Boolean,
    onQueryChange: (String) -> Unit,
    onApply: (LibraryMetadataMatch) -> Unit,
    onDismiss: () -> Unit,
) {
    val palette = Hearth.palette
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Find a better match") },
        text = {
            Column(
                Modifier.heightIn(max = 520.dp),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
            ) {
                OutlinedTextField(
                    value = query,
                    onValueChange = onQueryChange,
                    label = { Text("Search") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                if (searching) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        Text("Searching…", style = HearthText.Caption, color = palette.textSecondary)
                    }
                }
                LazyColumn(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    items(matches, key = { it.id }) { match ->
                        Column(
                            Modifier.fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .border(1.dp, palette.hairline, RoundedCornerShape(16.dp))
                                .clickable { onApply(match) }
                                .padding(Hearth.Spacing.M),
                        ) {
                            Text(match.title, style = HearthText.Label, color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            val source = match.sourceName.lowercase().replace('_', ' ').replaceFirstChar { it.titlecase() }
                            val byline = listOfNotNull(match.author, match.publishedYear?.toString(), source).joinToString(" · ")
                            if (byline.isNotBlank()) Text(byline, style = HearthText.Caption, color = palette.textSecondary)
                            Text("${(match.confidence * 100).toInt()}% · ${match.matchReason}", style = HearthText.Caption, color = palette.ember)
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
    )
}

@Composable
internal fun AudiobookshelfHistoryDialog(
    currentTarget: Book?,
    query: String,
    candidates: List<AudiobookshelfHistoryCandidate>,
    loading: Boolean,
    onQueryChange: (String) -> Unit,
    onLink: (AudiobookshelfHistoryCandidate) -> Unit,
    onUnlink: () -> Unit,
    onDismiss: () -> Unit,
) {
    val palette = Hearth.palette
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Share listening history") },
        text = {
            Column(Modifier.heightIn(max = 560.dp), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                Text(
                    "Choose the matching Audiobookshelf audiobook and account. You can share from now or separately include older local sessions. This does not grant server access.",
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                )
                currentTarget?.let {
                    Text("Current: ${it.title} · ${it.libraryName ?: it.connectionId.orEmpty()}", style = HearthText.Label)
                }
                OutlinedTextField(
                    value = query,
                    onValueChange = onQueryChange,
                    label = { Text("Search Audiobookshelf books") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                if (loading) CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                if (!loading && candidates.isEmpty()) Text("No Audiobookshelf audiobooks found.", style = HearthText.Body)
                LazyColumn(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    items(candidates, key = { it.book.uniqueKey }) { candidate ->
                        val target = candidate.book
                        Column(
                            Modifier.fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .border(1.dp, palette.hairline, RoundedCornerShape(16.dp))
                                .clickable { onLink(candidate) }
                                .padding(Hearth.Spacing.M),
                        ) {
                            Text(target.title, style = HearthText.Label, color = palette.text)
                            Text(
                                listOfNotNull(target.author, candidate.accountName, target.libraryName).joinToString(" · "),
                                style = HearthText.Caption,
                                color = palette.textSecondary,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            Row {
                if (currentTarget != null) TextButton(onClick = onUnlink) { Text("Stop sharing") }
                TextButton(onClick = onDismiss) { Text("Close") }
            }
        },
    )
}

@Composable
internal fun EditionLinkDialog(
    book: Book,
    currentLinked: Book?,
    query: String,
    candidates: List<LibraryLinkCandidate>,
    loading: Boolean,
    onQueryChange: (String) -> Unit,
    onLink: (LibraryLinkCandidate) -> Unit,
    onUnlink: () -> Unit,
    onDismiss: () -> Unit,
) {
    val palette = Hearth.palette
    val filteredCandidates = candidates.filter { it.book.uniqueKey != currentLinked?.uniqueKey }
    val title = if (book.mediaType == AppMediaType.EBOOK) "Link audiobook" else "Link ebook"
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(
                Modifier.heightIn(max = 560.dp),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
            ) {
                Text(
                    "Choose the matching ${if (book.mediaType == AppMediaType.EBOOK) "audiobook" else "ebook"} from your library. Picking one replaces any existing link on either book.",
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                )
                currentLinked?.let { linked ->
                    Column(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .border(1.dp, palette.hairline, RoundedCornerShape(16.dp))
                            .padding(Hearth.Spacing.M),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text("Current link", style = HearthText.Caption, color = palette.ember)
                        Text(linked.title, style = HearthText.Label, color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        val byline = listOfNotNull(linked.author, linked.source.displayName).joinToString(" · ")
                        if (byline.isNotBlank()) {
                            Text(byline, style = HearthText.Caption, color = palette.textSecondary)
                        }
                    }
                }
                OutlinedTextField(
                    value = query,
                    onValueChange = onQueryChange,
                    label = { Text("Search library") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                if (loading) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        Text("Looking for candidates…", style = HearthText.Caption, color = palette.textSecondary)
                    }
                }
                when {
                    !loading && filteredCandidates.isEmpty() -> {
                        Text(
                            if (query.isBlank()) "No opposite-format books are available to link yet." else "No books match that search.",
                            style = HearthText.Body,
                            color = palette.textSecondary,
                        )
                    }
                    else -> {
                        LazyColumn(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                            items(filteredCandidates, key = { it.book.uniqueKey }) { candidate ->
                                Column(
                                    Modifier.fillMaxWidth()
                                        .clip(RoundedCornerShape(16.dp))
                                        .border(1.dp, palette.hairline, RoundedCornerShape(16.dp))
                                        .clickable { onLink(candidate) }
                                        .padding(Hearth.Spacing.M),
                                ) {
                                    Text(candidate.book.title, style = HearthText.Label, color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    val byline = listOfNotNull(candidate.book.author, candidate.book.seriesName, candidate.book.source.displayName).joinToString(" · ")
                                    if (byline.isNotBlank()) {
                                        Text(byline, style = HearthText.Caption, color = palette.textSecondary)
                                    }
                                    Text(linkConfidenceLabel(candidate.confidence), style = HearthText.Caption, color = palette.ember)
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            Row {
                if (currentLinked != null) {
                    TextButton(onClick = onUnlink) { Text("Unlink") }
                }
                TextButton(onClick = onDismiss) { Text("Close") }
            }
        },
    )
}

private fun linkConfidenceLabel(confidence: Int): String =
    when {
        confidence >= 88 -> "$confidence% automatic match"
        confidence > 0 -> "$confidence% weak match"
        else -> "Manual link"
    }

internal fun supportsEditionLinking(book: Book): Boolean =
    book.mediaType == AppMediaType.EBOOK || book.mediaType == AppMediaType.AUDIOBOOK

internal fun String.blankToNull(): String? =
    trim().takeIf { it.isNotBlank() }
