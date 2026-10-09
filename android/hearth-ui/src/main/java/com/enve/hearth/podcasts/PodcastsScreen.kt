package com.enve.hearth.podcasts

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Podcasts
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
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
import com.enve.core.data.model.BookSource
import com.enve.engine.podcasts.PodcastDirectoryShow
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.ShelfHeader
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.hearthUI

private enum class PodcastsPage { HOME, BROWSE, STATS }

private val genres = listOf(
    "All" to null, "Comedy" to 1303, "True Crime" to 1488, "News" to 1489,
    "Society" to 1324, "Business" to 1321, "Health" to 1512, "Technology" to 1318,
    "Science" to 1533, "Education" to 1304, "History" to 1487, "Sports" to 1545,
    "Arts" to 1301, "Music" to 1310, "Fiction" to 1483, "Leisure" to 1502,
)

@Composable
fun PodcastsScreen(
    onOpenShow: (Book) -> Unit,
    onOpenEpisode: (Book) -> Unit,
    onPlay: (Book) -> Unit,
    vm: PodcastsViewModel = profileViewModel(),
) {
    val state by vm.state.collectAsStateWithLifecycle()
    val stats by vm.stats.collectAsStateWithLifecycle()
    var page by rememberSaveable { mutableStateOf(PodcastsPage.HOME) }
    val palette = Hearth.palette
    LazyColumn(
        Modifier.fillMaxSize().background(palette.bg).statusBarsPadding(),
        contentPadding = PaddingValues(bottom = LocalMantelInset.current + Hearth.Spacing.L),
    ) {
        item {
            Column(Modifier.padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.L)) {
                Overline("THE LISTENING ROOM")
                Text("Podcasts", style = hearthDisplay(34.sp, FontWeight.SemiBold), color = palette.text)
                Spacer(Modifier.height(Hearth.Spacing.M))
                Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    PodcastsPage.entries.forEach { choice ->
                        HearthChip(
                            label = choice.name.lowercase().replaceFirstChar(Char::uppercaseChar),
                            selected = page == choice,
                            onClick = { page = choice },
                        )
                    }
                }
            }
        }
        when (page) {
            PodcastsPage.HOME -> {
                if (state.loadingHome && state.home == null) item { Loading() }
                state.home?.let { home ->
                    if (home.upNext.isNotEmpty()) {
                        item { ShelfHeader("Up next", Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL)) }
                        item {
                            EpisodeFeature(home.upNext.first(), onOpenEpisode, onPlay)
                        }
                    }
                    if (home.newEpisodes.isNotEmpty()) {
                        item { ShelfHeader("New episodes", Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL)) }
                        items(home.newEpisodes, key = { "new-${it.uniqueKey}" }) { episode ->
                            EpisodeLine(episode, onOpenEpisode)
                        }
                    }
                    item {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Overline("YOUR SHOWS", modifier = Modifier.weight(1f))
                            Text(
                                "Browse",
                                style = HearthText.Caption,
                                color = palette.ember,
                                modifier = Modifier.clickable { page = PodcastsPage.BROWSE }.padding(Hearth.Spacing.S),
                            )
                        }
                    }
                    if (home.shows.isEmpty()) {
                        item {
                            EmptyMessage("A place for your favorite voices", "Explore shows or add an RSS feed to begin.", showIcon = false)
                            Column(Modifier.padding(horizontal = Hearth.Spacing.XXL)) {
                                EmberButton(
                                    "Browse podcasts",
                                    onClick = { page = PodcastsPage.BROWSE },
                                    leadingIcon = Icons.Outlined.Search,
                                )
                            }
                        }
                    } else {
                        item {
                            LazyRow(
                                contentPadding = PaddingValues(horizontal = Hearth.Spacing.XXL),
                                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
                            ) {
                                items(home.shows.indices.toList(), key = { home.showBooks[it].uniqueKey }) { index ->
                                    val show = home.shows[index]
                                    ShowTile(show.title, show.coverUrl, show.author) {
                                        onOpenShow(home.showBooks[index])
                                    }
                                }
                            }
                        }
                    }
                }
                if (state.error != null) item { EmptyMessage("Couldn't refresh podcasts", state.error.orEmpty()) }
            }
            PodcastsPage.BROWSE -> {
                item {
                    OutlinedTextField(
                        value = state.query,
                        onValueChange = vm::search,
                        label = { Text("Search podcasts") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL),
                    )
                    Spacer(Modifier.height(Hearth.Spacing.M))
                    Row(
                        Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Hearth.Spacing.XXL),
                        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                    ) {
                        genres.forEach { (name, id) ->
                            HearthChip(name, selected = state.genreId == id, onClick = { vm.setGenre(id) })
                        }
                    }
                    Spacer(Modifier.height(Hearth.Spacing.M))
                    var feedUrl by rememberSaveable { mutableStateOf("") }
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        OutlinedTextField(
                            value = feedUrl,
                            onValueChange = { feedUrl = it },
                            label = { Text("Add RSS feed URL") },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                        )
                        QuietButton("Add", onClick = {
                            if (feedUrl.isNotBlank()) {
                                vm.subscribeToFeed(feedUrl.trim())
                                feedUrl = ""
                            }
                        })
                    }
                }
                item {
                    ShelfHeader(
                        if (state.query.isBlank()) "Top podcasts" else "Search results",
                        Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.M),
                    )
                }
                if (state.loadingDirectory) item { Loading() }
                items(state.directory, key = PodcastDirectoryShow::id) { show ->
                    val subscribed = state.subscriptions.any { it.feedUrl == show.feedUrl }
                    Row(
                        Modifier.fillMaxWidth().clickable { onOpenShow(show.asBook()) }
                            .padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.S),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
                    ) {
                        CoverTile(model = show.coverUrl, mediaType = AppMediaType.PODCAST, modifier = Modifier.width(64.dp))
                        Column(Modifier.weight(1f)) {
                            Text(show.title, style = hearthUI(14.sp, FontWeight.SemiBold), color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            show.author?.let {
                                Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                        QuietButton(if (subscribed) "Added" else "Follow", onClick = {
                            if (!subscribed) vm.subscribe(show)
                        })
                    }
                }
                if (!state.loadingDirectory && state.directory.isEmpty()) item {
                    EmptyMessage("No shows found", "Try a different title or add a feed URL.")
                }
                state.error?.let { error -> item { EmptyMessage("Couldn't load podcasts", error) } }
            }
            PodcastsPage.STATS -> {
                item {
                    Column(Modifier.padding(Hearth.Spacing.XXL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXL)) {
                        Overline("PODCAST LISTENING")
                        Text("The record", style = hearthDisplay(26.sp, FontWeight.SemiBold), color = palette.text)
                        Text("Level ${stats.level} · ${stats.rank}", style = HearthText.Body, color = palette.ember)
                        StatLine("Hours", String.format("%.1f", stats.totalSeconds / 3600.0))
                        StatLine("Sessions", "${stats.sessions}")
                        StatLine("Finished", "${stats.finished}")
                        StatLine("Shows", "${stats.shows}")
                    }
                }
                if (stats.topShows.isNotEmpty()) {
                    item { ShelfHeader("Top shows", Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL)) }
                    items(stats.topShows.take(5), key = { it.first }) { (name, seconds) ->
                        Row(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.M)) {
                            Text(name, style = HearthText.Body, color = palette.text, modifier = Modifier.weight(1f))
                            Text(String.format("%.1fh", seconds / 3600.0), style = HearthText.Caption, color = palette.textSecondary)
                        }
                    }
                }
                if (stats.topEpisodes.isNotEmpty()) {
                    item { ShelfHeader("Top episodes", Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL)) }
                    items(stats.topEpisodes.take(5), key = { it.first.uniqueKey }) { (book, _) -> EpisodeLine(book, onOpenEpisode) }
                }
                if (stats.sessions == 0) item { EmptyMessage("Your story starts here", "Listen to an episode to begin your podcast record.") }
            }
        }
    }
}

private fun PodcastDirectoryShow.asBook(): Book = Book(
    id = feedUrl,
    title = title,
    author = author,
    coverUrl = coverUrl,
    source = BookSource.LOCAL,
    mediaType = AppMediaType.PODCAST,
    podcastName = title,
)

@Composable
private fun ShowTile(title: String, coverUrl: String?, author: String?, onClick: () -> Unit) {
    val palette = Hearth.palette
    Column(Modifier.width(136.dp).clickable(onClick = onClick)) {
        CoverTile(model = coverUrl, mediaType = AppMediaType.PODCAST, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(Hearth.Spacing.S))
        Text(title, style = hearthUI(13.sp, FontWeight.SemiBold), color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
        author?.let { Text(it, style = hearthUI(11.sp), color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
    }
}

@Composable
private fun EpisodeFeature(book: Book, onOpenEpisode: (Book) -> Unit, onPlay: (Book) -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().clickable { onOpenEpisode(book) }.padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.M),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        CoverTile(model = book.coverUrl, mediaType = AppMediaType.PODCAST, modifier = Modifier.width(94.dp))
        Column(Modifier.weight(1f)) {
            Overline("CONTINUE LISTENING")
            Text(book.title, style = hearthDisplay(18.sp, FontWeight.SemiBold), color = palette.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
            Text(book.podcastName.orEmpty(), style = HearthText.Caption, color = palette.textSecondary)
        }
        Icon(Icons.Filled.PlayArrow, contentDescription = "Play ${book.title}", tint = palette.ember, modifier = Modifier.size(28.dp).clickable { onPlay(book) })
    }
}

@Composable
private fun EpisodeLine(book: Book, onOpenEpisode: (Book) -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().clickable { onOpenEpisode(book) }.padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        CoverTile(model = book.coverUrl, mediaType = AppMediaType.PODCAST, modifier = Modifier.width(52.dp))
        Column(Modifier.weight(1f)) {
            Text(book.title, style = hearthUI(14.sp, FontWeight.SemiBold), color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(book.podcastName.orEmpty(), style = HearthText.Caption, color = palette.textSecondary)
        }
        Icon(Icons.Outlined.Podcasts, contentDescription = "Open ${book.title}", tint = palette.ember)
    }
}

@Composable
private fun StatLine(label: String, value: String) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = HearthText.Body, color = palette.textSecondary, modifier = Modifier.weight(1f))
        Text(value, style = hearthDisplay(23.sp, FontWeight.SemiBold), color = palette.text)
    }
}

@Composable
private fun EmptyMessage(title: String, detail: String, showIcon: Boolean = true) {
    val palette = Hearth.palette
    Column(Modifier.fillMaxWidth().padding(Hearth.Spacing.XXL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        if (showIcon) Icon(Icons.Outlined.Add, contentDescription = null, tint = palette.ember)
        Text(title, style = hearthDisplay(19.sp, FontWeight.SemiBold), color = palette.text)
        Text(detail, style = HearthText.Caption, color = palette.textSecondary)
    }
}

@Composable
private fun Loading() {
    Column(Modifier.fillMaxWidth().padding(Hearth.Spacing.XXL), horizontalAlignment = Alignment.CenterHorizontally) {
        CircularProgressIndicator(color = Hearth.palette.ember)
    }
}
