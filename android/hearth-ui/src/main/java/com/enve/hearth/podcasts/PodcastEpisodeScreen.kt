package com.enve.hearth.podcasts

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.hearth.shell.profileViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.engine.library.LibraryDownloadStatus
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.Ribbon
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.hearthUI

@Composable
fun PodcastEpisodeScreen(
    episode: Book,
    onBack: () -> Unit,
    onPlay: (Book) -> Unit,
    vm: PodcastEpisodeViewModel = profileViewModel(),
) {
    LaunchedEffect(episode.uniqueKey) { vm.load(episode) }
    val download by vm.download.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    var notesExpanded by rememberSaveable(episode.uniqueKey) { mutableStateOf(false) }
    val notes = episode.description?.let(PodcastsFormat::cleanHTML)?.takeIf(String::isNotBlank)
    Column(
        Modifier.fillMaxSize().background(palette.bg).verticalScroll(rememberScrollState()).statusBarsPadding(),
    ) {
        Icon(
            Icons.AutoMirrored.Outlined.ArrowBack,
            contentDescription = "Back",
            tint = palette.text,
            modifier = Modifier.padding(Hearth.Spacing.M).clickable(onClick = onBack).padding(Hearth.Spacing.M),
        )
        Column(
            Modifier.padding(horizontal = Hearth.Spacing.XXL),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXL),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.L)) {
                CoverTile(
                    model = episode.coverUrl,
                    mediaType = AppMediaType.PODCAST,
                    modifier = Modifier.width(118.dp),
                )
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS)) {
                    Overline("THE EPISODE")
                    Text(
                        episode.title,
                        style = hearthDisplay(20.sp, FontWeight.SemiBold),
                        color = palette.text,
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis,
                    )
                    episode.podcastName?.let { Text(it, style = HearthText.Caption, color = palette.ember) }
                    PodcastsFormat.publishedDate(episode.addedOn)?.let {
                        Text(it, style = hearthUI(12.sp), color = palette.textTertiary)
                    }
                    if (episode.isFinished) Text("Played", style = HearthText.Caption, color = palette.statusOK)
                }
            }
            if (PodcastsFormat.isInProgress(episode)) {
                Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    Ribbon(progress = episode.progress)
                    Row(Modifier.fillMaxWidth()) {
                        Text("${(episode.progress * 100).toInt()}% heard", style = HearthText.Caption, color = palette.textTertiary)
                        Spacer(Modifier.weight(1f))
                        Text(episode.displayRemainingTime + " left", style = HearthText.Caption, color = palette.textTertiary)
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                EmberButton(
                    if (PodcastsFormat.isInProgress(episode)) "Resume" else "Play",
                    onClick = { onPlay(episode) },
                )
                QuietButton(
                    when (download.status) {
                        LibraryDownloadStatus.COMPLETED -> "Remove download"
                        LibraryDownloadStatus.DOWNLOADING -> "${(download.progress * 100).toInt()}%"
                        LibraryDownloadStatus.QUEUED -> "Queued"
                        else -> "Download"
                    },
                    onClick = { vm.toggleDownload(episode) },
                )
            }
            download.errorMessage?.let {
                Text(it, style = HearthText.Caption, color = palette.statusError)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                Text(
                    if (episode.duration > 0L) PodcastsFormat.duration(episode.duration) else "Unknown length",
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                )
                if (episode.isFeedOnlyEpisode) Text("RSS episode", style = HearthText.Caption, color = palette.textSecondary)
            }
            notes?.let {
                Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    Overline("EPISODE NOTES")
                    Text(
                        it,
                        style = hearthUI(14.sp),
                        color = palette.textSecondary,
                        maxLines = if (notesExpanded) Int.MAX_VALUE else 6,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (it.length > 200) {
                        Text(
                            if (notesExpanded) "Show less" else "Show more",
                            style = HearthText.Caption,
                            color = palette.ember,
                            modifier = Modifier.clickable { notesExpanded = !notesExpanded },
                        )
                    }
                }
            }
            episode.podcastName?.let {
                Text(it, style = hearthUI(14.sp, FontWeight.Medium), color = palette.text)
            }
            Spacer(Modifier.height(LocalMantelInset.current + Hearth.Spacing.L))
        }
    }
}
