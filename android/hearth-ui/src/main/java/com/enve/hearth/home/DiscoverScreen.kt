package com.enve.hearth.home

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.hearth.shell.profileViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.engine.discover.DiscoverBook
import com.enve.engine.discover.DiscoverSection
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.ShelfHeader
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.hearthUI

@Composable
internal fun DiscoverScreen(onBack: () -> Unit, onOpenBook: (Book) -> Unit, onPlayBook: (Book) -> Unit, vm: DiscoverViewModel = profileViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    var sectionId by rememberSaveable { mutableStateOf<String?>(null) }
    var bookId by rememberSaveable { mutableStateOf<String?>(null) }
    val section = state.sections.firstOrNull { it.id == sectionId }
    val book = state.sections.asSequence().flatMap { it.books.asSequence() }.firstOrNull { it.id == bookId }
    val back = {
        when {
            bookId != null -> bookId = null
            sectionId != null -> sectionId = null
            else -> onBack()
        }
    }
    BackHandler(onBack = back)
    val palette = Hearth.palette
    LazyColumn(
        Modifier.fillMaxSize().background(palette.bg).statusBarsPadding(),
        contentPadding = PaddingValues(bottom = LocalMantelInset.current + Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
    ) {
        item { DiscoverHeader(if (book != null) "Book details" else section?.title ?: "Discover", back, { vm.load(true) }) }
        when {
            state.loading && state.sections.isEmpty() -> item { Box(Modifier.fillMaxWidth().height(160.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = palette.ember) } }
            state.error != null && state.sections.isEmpty() -> item { DiscoverUnavailable(state.error ?: "Nothing arrived.") { vm.load(true) } }
            book != null -> item { DiscoverDetail(book, onOpenBook, onPlayBook) }
            section != null -> {
                item { Text(section.subtitle, style = HearthText.Body, color = palette.textSecondary, modifier = Modifier.padding(horizontal = Hearth.Spacing.XL)) }
                items(section.books.chunked(3)) { row ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                        row.forEach { entry -> Box(Modifier.weight(1f)) { DiscoverTile(entry) { bookId = entry.id } } }
                        repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
            else -> {
                item {
                    Column(Modifier.padding(horizontal = Hearth.Spacing.XL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS)) {
                        Overline("THE WIDER WORLD")
                        Text("What other readers are listening to.", style = HearthText.Body, color = palette.textSecondary)
                    }
                }
                state.sections.forEach { shelf ->
                    item { ShelfHeader(shelf.title, Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL), "See all") { sectionId = shelf.id } }
                    item {
                        LazyRow(contentPadding = PaddingValues(horizontal = Hearth.Spacing.XL), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                            items(shelf.books.take(12), key = { it.id }) { entry ->
                                Box(Modifier.width(108.dp)) { DiscoverTile(entry) { bookId = entry.id } }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DiscoverUnavailable(message: String, onRetry: () -> Unit) {
    val palette = Hearth.palette
    Column(
        Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.XXL),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Icon(Icons.Outlined.WifiOff, null, tint = palette.textTertiary)
        Text("The charts are out of reach.", style = hearthDisplay(19.sp, FontWeight.SemiBold), color = palette.text)
        Text(message, style = HearthText.Caption, color = palette.textSecondary)
        QuietButton("Try again", onClick = onRetry)
    }
}

@Composable
private fun DiscoverHeader(title: String, onBack: () -> Unit, onRefresh: () -> Unit) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.L), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back", tint = palette.text, modifier = Modifier.clickable(onClick = onBack).padding(8.dp))
        Text(title, style = hearthDisplay(30.sp, FontWeight.SemiBold), color = palette.text, modifier = Modifier.weight(1f).padding(start = Hearth.Spacing.M))
        Icon(Icons.Outlined.Refresh, "Refresh", tint = palette.textSecondary, modifier = Modifier.clickable(onClick = onRefresh).padding(8.dp))
    }
}

@Composable
private fun DiscoverTile(book: DiscoverBook, onClick: () -> Unit) {
    val palette = Hearth.palette
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS)) {
        CoverTile(book.artworkUrl, mediaType = AppMediaType.EBOOK, modifier = Modifier.fillMaxWidth())
        Text(book.title, style = hearthDisplay(13.sp, FontWeight.Medium), color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
        book.author?.let { Text(it, style = hearthUI(11.sp), color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        if (book.libraryMatch != null) Overline("IN YOUR LIBRARY", color = palette.ember)
    }
}

@Composable
private fun DiscoverDetail(book: DiscoverBook, onOpenBook: (Book) -> Unit, onPlayBook: (Book) -> Unit) {
    val palette = Hearth.palette
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.L)) {
            CoverTile(book.artworkUrl, mediaType = AppMediaType.EBOOK, modifier = Modifier.width(120.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                Text(book.title, style = hearthDisplay(23.sp, FontWeight.SemiBold), color = palette.text)
                book.author?.let { Text(it, style = HearthText.Body, color = palette.textSecondary) }
            }
        }
        book.libraryMatch?.let { match ->
            Text("Already on your shelves.", style = HearthText.Body, color = palette.statusOK)
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S), verticalAlignment = Alignment.CenterVertically) {
                QuietButton("Open in library", onClick = { onOpenBook(match) })
                EmberButton(
                    if (match.progress > 0f) "Continue" else if (match.mediaType == AppMediaType.EBOOK) "Read" else "Listen",
                    onClick = { onPlayBook(match) },
                )
            }
        } ?: Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS)) {
            Text("Not in any connected library.", style = HearthText.Body, color = palette.textSecondary)
            Text("Add a source that carries this book to read or listen here.", style = HearthText.Caption, color = palette.textTertiary)
        }
        val facts = listOfNotNull(book.publishedDate?.take(4), book.genre, book.pageCount?.let { "$it pages" }, book.durationMillis?.let { "${it / 3_600_000}h ${(it / 60_000) % 60}m" })
        if (facts.isNotEmpty()) Text(facts.joinToString(" · "), style = HearthText.Caption, color = palette.textSecondary)
        book.description?.takeIf { it.isNotBlank() }?.let { Text(it, style = HearthText.Body, color = palette.text) }
    }
}
