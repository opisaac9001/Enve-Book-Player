package com.enve.app.data.offline.resolvers

import com.enve.core.data.model.Book
import com.enve.app.data.offline.AudiobookTrackResolver
import com.enve.app.data.offline.ResolvedTrack
import com.enve.audiobookshelf.AudiobookshelfRepository
import javax.inject.Inject

class AudiobookshelfTrackResolver @Inject constructor(
    private val repository: AudiobookshelfRepository,
) : AudiobookTrackResolver {

    override suspend fun resolveTracks(book: Book): Result<List<ResolvedTrack>> = runCatching {
        book.podcastEnclosureUrl?.let { url ->
            return@runCatching listOf(
                ResolvedTrack(
                    index = 0,
                    title = book.title,
                    durationMs = book.duration * 1000L,
                    url = url,
                ),
            )
        }
        val tracks = repository.getAudioTracks(book).getOrThrow()
        if (tracks.isEmpty()) error("Audiobookshelf returned no tracks for ${book.title}")
        tracks.map { track ->
            val url = track.contentUrl ?: error("Audiobookshelf track ${track.index} has no contentUrl")
            ResolvedTrack(
                index = track.index,
                title = track.title ?: track.fileName,
                durationMs = track.durationMs,
                url = url,
            )
        }
    }
}
