package com.enve.hearth.detail

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthFormat
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.engine.bookorbit.BookOrbitRelatedBook
import com.enve.hearth.design.ShelfHeader

internal fun stripHtml(html: String): String =
    html.replace(Regex("(?i)<br\\s*/?>"), "\n")
        .replace(Regex("(?i)</p>"), "\n\n")
        .replace(Regex("<[^>]+>"), "")
        .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
        .replace("&quot;", "\"").replace("&#39;", "'").replace("&apos;", "'").replace("&nbsp;", " ")
        .replace(Regex("[ \\t]+"), " ")
        .replace(Regex("\\n{3,}"), "\n\n")
        .trim()

@Composable
internal fun DetailDescription(text: String) {
    val palette = Hearth.palette
    var expanded by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.L)) {
        Overline("About")
        Spacer(Modifier.height(Hearth.Spacing.S))
        Text(
            text,
            style = HearthText.Body,
            color = palette.textSecondary,
            maxLines = if (expanded) Int.MAX_VALUE else 4,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.animateContentSize().clickable { expanded = !expanded },
        )
    }
}

@Composable
internal fun AboutGrid(b: Book) {
    val palette = Hearth.palette
    val entries = buildList {
        if (b.mediaType != AppMediaType.EBOOK && b.duration > 0) add("Length" to durationHm(b.duration))
        b.pageCount?.takeIf { it > 0 }?.let { add("Pages" to it.toString()) }
        b.publishedDate?.take(4)?.takeIf { it.length == 4 }?.let { add("Year" to it) }
        b.primaryFileType?.takeIf { it.isNotBlank() }?.let { add("Format" to it.uppercase()) }
        b.language?.takeIf { it.isNotBlank() }?.let { add("Language" to it.uppercase()) }
        b.publisher?.takeIf { it.isNotBlank() }?.let { add("Publisher" to it) }
    }
    if (entries.isEmpty() && b.categories.isEmpty()) return
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.L), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        Overline("Details")
        entries.forEach { (label, value) ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(label, style = HearthText.Caption, color = palette.textTertiary)
                Text(value, style = HearthText.Caption, color = palette.text)
            }
        }
        if (b.categories.isNotEmpty()) {
            Text(b.categories.joinToString(" · "), style = HearthText.Caption, color = palette.textSecondary)
        }
    }
}

@Composable
internal fun BookShelfRow(title: String, books: List<Book>, onOpen: (Book) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = Hearth.Spacing.XL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        ShelfHeader(title, modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL))
        LazyRow(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Hearth.Spacing.XL),
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        ) {
            items(books, key = { it.id + (it.connectionId ?: "") }) { book ->
                CoverTile(
                    model = book.coverUrl,
                    mediaType = book.mediaType,
                    modifier = Modifier.width(108.dp).clickable { onOpen(book) },
                )
            }
        }
    }
}

@Composable
internal fun RelatedShelf(
    title: String,
    books: List<BookOrbitRelatedBook>,
    onOpen: (Int) -> Unit,
) {
    val palette = Hearth.palette
    Column(Modifier.fillMaxWidth().padding(top = Hearth.Spacing.XL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        ShelfHeader(title, modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL))
        LazyRow(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Hearth.Spacing.XL),
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        ) {
            items(books, key = { it.bookId }) { related ->
                Column(
                    Modifier.width(108.dp).clickable { onOpen(related.bookId) },
                    verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
                ) {
                    CoverTile(model = related.coverUrl, contentDescription = related.title)
                    Text(
                        related.title,
                        style = HearthText.Caption,
                        color = palette.text,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    related.seriesLabel?.let {
                        Text(it, style = HearthText.Caption, color = palette.textTertiary, maxLines = 1)
                    }
                }
            }
        }
    }
}

internal fun relatedShelfTitle(source: BookSource): String = when (source) {
    BookSource.SILO -> "Silo suggests"
    else -> "You might also like"
}

internal fun detailStatusLine(b: Book, chapters: List<Chapter>): String {
    val timeLeft = HearthFormat.timeLeft(b)
    if (chapters.isNotEmpty() && b.mediaType != AppMediaType.EBOOK) {
        val index = chapters.indexOfLast { it.startTime <= b.currentTime }.coerceAtLeast(0)
        val chapterLine = "Chapter ${index + 1} of ${chapters.size}"
        return listOfNotNull(chapterLine, timeLeft).joinToString(" · ")
    }
    val pct = (HearthFormat.progress(b) * 100).toInt()
    return if (b.isFinished) "Finished" else listOfNotNull("$pct% complete", timeLeft).joinToString(" · ")
}

private fun durationHm(seconds: Long): String {
    val h = seconds / 3600; val m = (seconds % 3600) / 60
    return if (h > 0) "${h}h ${m}m" else "${m}m"
}
