package com.enve.audiobookshelf

import com.enve.audiobookshelf.dto.AbsLibraryItemDto
import com.enve.audiobookshelf.dto.AbsMediaProgressDto
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.PodcastFeedKey
import com.enve.core.data.model.PodcastShow

internal fun mapAbsPodcastShow(
    item: AbsLibraryItemDto,
    progress: List<AbsMediaProgressDto>,
    serverUrl: String,
): PodcastShow {
    val metadata = item.media?.metadata
    val title = metadata?.title?.takeIf { it.isNotBlank() } ?: "(Untitled)"
    val author = metadata?.author?.takeIf { it.isNotBlank() }
    val coverUrl = "${serverUrl.trimEnd('/')}/api/items/${item.id}/cover"
    val progressByEpisodeId = progress
        .filter { it.libraryItemId == item.id }
        .mapNotNull { entry -> entry.episodeId?.let { it to entry } }
        .toMap()
    val episodes = item.media?.episodes.orEmpty().mapNotNull { episode ->
        val episodeTitle = episode.title?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
        val base = Book(
            id = "${item.id}_${episode.id}",
            title = episodeTitle,
            author = author,
            description = episode.description?.takeIf { it.isNotBlank() },
            coverUrl = coverUrl,
            duration = (episode.duration ?: episode.audioFile?.duration ?: 0.0).toLong(),
            source = BookSource.AUDIOBOOKSHELF,
            mediaType = AppMediaType.PODCAST,
            libraryId = item.libraryId,
            addedOn = episode.publishedAt ?: episode.addedAt ?: 0L,
            hasAudio = true,
            podcastName = title,
            episodeId = episode.id,
            podcastLibraryItemId = item.id,
        )
        progressByEpisodeId[episode.id]?.let { applyAbsMediaProgress(base, it) } ?: base
    }
    return PodcastShow(
        id = item.id,
        title = title,
        author = author,
        description = metadata?.description?.takeIf { it.isNotBlank() },
        coverUrl = coverUrl,
        genres = metadata?.genres.orEmpty(),
        episodes = episodes,
        feedUrl = metadata?.feedUrl?.trim()?.takeIf { it.isNotEmpty() },
        storedFeedKeys = item.media?.episodes.orEmpty().map { episode ->
            PodcastFeedKey(
                guid = episode.guid?.trim()?.takeIf { it.isNotEmpty() },
                enclosureUrl = episode.enclosure?.url?.trim()?.takeIf { it.isNotEmpty() },
                title = episode.title.orEmpty(),
                publishedAtMs = episode.publishedAt,
            )
        },
    )
}
