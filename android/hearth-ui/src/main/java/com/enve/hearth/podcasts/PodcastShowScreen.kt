package com.enve.hearth.podcasts

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
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
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Podcasts
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.core.data.model.PodcastShow
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.Ribbon
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.hearthUI

@Composable
fun PodcastShowScreen(
    initial: Book,
    onBack: () -> Unit,
    onPlay: (Book) -> Unit,
) {
    val vm: PodcastShowViewModel = hiltViewModel()
    LaunchedEffect(initial.uniqueKey) { vm.load(initial) }
    LifecycleResumeEffect(vm) {
        vm.refresh()
        onPauseOrDispose { }
    }
    val state by vm.state.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    val show = (state.load as? PodcastShowLoad.Loaded)?.show

    LazyColumn(
        Modifier.fillMaxSize().background(palette.bg),
        contentPadding = PaddingValues(bottom = LocalMantelInset.current + Hearth.Spacing.L),
    ) {
        item { ShowHeader(initial, show, state.episodes.size, onBack) }
        when (state.load) {
            PodcastShowLoad.Loading -> item { ShowLoading() }
            PodcastShowLoad.Failed -> item {
                ShowMessage("Couldn't open this show.", "Check the Audiobookshelf connection and try again.") {
                    QuietButton("Try again", onClick = vm::retry)
                }
            }
            is PodcastShowLoad.Loaded -> if (state.episodes.isEmpty()) {
                item { ShowMessage("No episodes yet.", "Audiobookshelf hasn't downloaded any episodes of this show.") }
            } else {
                item { ShowTally(state) }
                if (state.inProgress.isNotEmpty()) {
                    item { SectionOverline("Still playing") }
                    items(state.inProgress, key = { "playing-${it.id}" }) { episode ->
                        EpisodeRow(episode, onPlay, showDivider = false)
                    }
                }
                item { EpisodeControls(state.query, state.newestFirst, vm::setQuery, vm::toggleOrder) }
                item { SectionOverline("All episodes") }
                if (state.visibleEpisodes.isEmpty()) {
                    item {
                        Text(
                            "No episodes match.",
                            style = HearthText.Caption,
                            color = palette.textSecondary,
                            modifier = Modifier.padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.XXL),
                        )
                    }
                } else {
                    items(state.visibleEpisodes, key = { it.id }) { episode ->
                        EpisodeRow(episode, onPlay, showDivider = episode.id != state.visibleEpisodes.last().id)
                    }
                }
            }
        }
    }
}

@Composable
private fun ShowHeader(initial: Book, show: PodcastShow?, episodeCount: Int, onBack: () -> Unit) {
    val palette = Hearth.palette
    var descriptionExpanded by rememberSaveable(initial.uniqueKey) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().statusBarsPadding()) {
        Icon(
            Icons.AutoMirrored.Outlined.ArrowBack,
            contentDescription = "Back",
            tint = palette.text,
            modifier = Modifier
                .padding(Hearth.Spacing.S)
                .clip(CircleShape)
                .clickable(role = Role.Button, onClick = onBack)
                .padding(Hearth.Spacing.S)
                .size(26.dp),
        )
        Column(Modifier.padding(horizontal = Hearth.Spacing.XXL)) {
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.L)) {
                CoverTile(
                    model = show?.coverUrl ?: initial.coverUrl,
                    mediaType = initial.mediaType,
                    modifier = Modifier.width(118.dp),
                )
                Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Overline("The show")
                    Text(
                        show?.title ?: initial.title,
                        style = hearthDisplay(22.sp, FontWeight.SemiBold),
                        color = palette.text,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                    (show?.author ?: initial.author)?.let {
                        Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                    if (episodeCount > 0) {
                        Text(
                            if (episodeCount == 1) "1 episode" else "$episodeCount episodes",
                            style = hearthUI(12.sp),
                            color = palette.textTertiary,
                        )
                    }
                    show?.genres?.takeIf { it.isNotEmpty() }?.let { genres ->
                        Text(
                            genres.joinToString(" · "),
                            style = hearthUI(11.sp),
                            color = palette.textTertiary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            (show?.description ?: initial.description)?.let(PodcastsFormat::cleanHTML)?.takeIf { it.isNotEmpty() }?.let { description ->
                Text(
                    description,
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                    maxLines = if (descriptionExpanded) Int.MAX_VALUE else 3,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .padding(top = Hearth.Spacing.L)
                        .clickable(role = Role.Button) { descriptionExpanded = !descriptionExpanded },
                )
            }
        }
    }
}

@Composable
private fun ShowTally(state: PodcastShowUiState) {
    val palette = Hearth.palette
    val shape = if (Hearth.eink.sharpCorners) RectangleShape else RoundedCornerShape(Hearth.Radius.Card)
    Row(
        Modifier
            .padding(horizontal = Hearth.Spacing.XXL)
            .padding(top = Hearth.Spacing.XXL)
            .fillMaxWidth()
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .padding(vertical = 14.dp),
    ) {
        TallyColumn("${state.unplayedCount}", "Unplayed")
        TallyColumn("${state.playingCount}", "Playing")
        TallyColumn("${state.playedCount}", "Played")
        TallyColumn("${state.totalHours}h", "In total")
    }
}

@Composable
private fun RowScope.TallyColumn(value: String, label: String) {
    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, style = hearthDisplay(20.sp, FontWeight.SemiBold), color = Hearth.palette.text)
        Spacer(Modifier.height(Hearth.Spacing.XS))
        Overline(label, color = Hearth.palette.textTertiary)
    }
}

@Composable
private fun SectionOverline(text: String) {
    Overline(
        text,
        modifier = Modifier
            .padding(horizontal = Hearth.Spacing.XXL)
            .padding(top = Hearth.Spacing.XXL, bottom = Hearth.Spacing.XS),
    )
}

@Composable
private fun EpisodeControls(
    query: String,
    newestFirst: Boolean,
    onQuery: (String) -> Unit,
    onToggleOrder: () -> Unit,
) {
    val palette = Hearth.palette
    val keyboard = LocalSoftwareKeyboardController.current
    val shape = if (Hearth.eink.sharpCorners) RectangleShape else RoundedCornerShape(50)
    Row(
        Modifier.padding(horizontal = Hearth.Spacing.XXL).padding(top = Hearth.Spacing.XXL),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier
                .weight(1f)
                .clip(shape)
                .background(palette.bgElevated)
                .border(1.dp, palette.hairline, shape)
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.Search, contentDescription = null, tint = palette.textTertiary, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(10.dp))
            Box(Modifier.weight(1f)) {
                if (query.isEmpty()) {
                    Text("Search episodes…", style = hearthUI(14.sp), color = palette.textTertiary)
                }
                BasicTextField(
                    value = query,
                    onValueChange = onQuery,
                    singleLine = true,
                    textStyle = hearthUI(14.sp).copy(color = palette.text),
                    cursorBrush = SolidColor(palette.ember),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { keyboard?.hide() }),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            if (query.isNotEmpty()) {
                Icon(
                    Icons.Outlined.Close,
                    contentDescription = "Clear search",
                    tint = palette.textTertiary,
                    modifier = Modifier
                        .clip(CircleShape)
                        .clickable(role = Role.Button) { onQuery("") }
                        .size(18.dp),
                )
            }
        }
        GlyphButton(
            icon = if (newestFirst) Icons.Filled.ArrowDownward else Icons.Filled.ArrowUpward,
            label = if (newestFirst) "Newest first" else "Oldest first",
            onClick = onToggleOrder,
        )
    }
}

@Composable
private fun EpisodeRow(episode: Book, onPlay: (Book) -> Unit, showDivider: Boolean) {
    val palette = Hearth.palette
    var notesExpanded by rememberSaveable(episode.id) { mutableStateOf(false) }
    val notes = episode.description?.let(PodcastsFormat::cleanHTML)?.takeIf { it.isNotEmpty() }
    Column(Modifier.padding(horizontal = Hearth.Spacing.XXL)) {
        Column(
            Modifier
                .fillMaxWidth()
                .then(if (notes != null) Modifier.clickable { notesExpanded = !notesExpanded } else Modifier)
                .padding(vertical = Hearth.Spacing.M),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                CoverTile(model = episode.coverUrl, mediaType = episode.mediaType, modifier = Modifier.width(50.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        episode.title,
                        style = hearthUI(14.sp, FontWeight.SemiBold),
                        color = palette.text,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    listOfNotNull(
                        episode.duration.takeIf { it > 0L }?.let(PodcastsFormat::duration),
                        PodcastsFormat.publishedDate(episode.addedOn),
                    ).takeIf { it.isNotEmpty() }?.let {
                        Text(it.joinToString(" · "), style = hearthUI(11.sp), color = palette.textTertiary)
                    }
                    EpisodeStatus(episode)
                }
                GlyphButton(icon = Icons.Filled.PlayArrow, label = "Play ${episode.title}", onClick = { onPlay(episode) })
            }
            notes?.let {
                Text(
                    it,
                    style = hearthUI(12.sp),
                    color = palette.textSecondary,
                    maxLines = if (notesExpanded) Int.MAX_VALUE else 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (PodcastsFormat.isInProgress(episode)) {
                Ribbon(progress = episode.progress)
            }
        }
        if (showDivider) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(palette.hairline))
        }
    }
}

@Composable
private fun EpisodeStatus(episode: Book) {
    val palette = Hearth.palette
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        when {
            episode.isFinished -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS)) {
                Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = palette.statusOK, modifier = Modifier.size(12.dp))
                Text("Played", style = hearthUI(11.sp, FontWeight.Medium), color = palette.statusOK)
            }
            PodcastsFormat.isStarted(episode) -> Text(
                "${(episode.progress * 100).toInt()}% played",
                style = hearthUI(11.sp, FontWeight.Medium),
                color = palette.ember,
            )
        }
        if (episode.isFeedOnlyEpisode) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS)) {
                Icon(Icons.Outlined.Podcasts, contentDescription = null, tint = palette.textTertiary, modifier = Modifier.size(12.dp))
                Text("Not on server", style = hearthUI(11.sp, FontWeight.Medium), color = palette.textTertiary)
            }
        }
    }
}

@Composable
private fun GlyphButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    val palette = Hearth.palette
    val shape = if (Hearth.eink.sharpCorners) RectangleShape else CircleShape
    Box(
        Modifier
            .size(44.dp)
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, tint = palette.text, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun ShowLoading() {
    val palette = Hearth.palette
    Column(
        Modifier.fillMaxWidth().padding(top = 60.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        CircularProgressIndicator(color = palette.ember, trackColor = palette.hairline)
        Text("Opening the feed…", style = HearthText.Caption, color = palette.textSecondary)
    }
}

@Composable
private fun ShowMessage(title: String, line: String, action: @Composable () -> Unit = {}) {
    val palette = Hearth.palette
    Column(
        Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL).padding(top = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Text(title, style = hearthDisplay(20.sp, FontWeight.SemiBold), color = palette.text)
        Text(line, style = HearthText.Caption, color = palette.textSecondary)
        action()
    }
}
