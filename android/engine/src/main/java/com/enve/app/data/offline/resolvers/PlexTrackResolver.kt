package com.enve.app.data.offline.resolvers

import com.enve.app.data.offline.AudiobookTrackResolver
import com.enve.app.data.offline.ResolvedTrack
import com.enve.core.data.model.Book
import com.enve.plex.PlexRepository
import javax.inject.Inject

class PlexTrackResolver @Inject constructor(
    private val repository: PlexRepository,
) : AudiobookTrackResolver {

    override suspend fun resolveTracks(book: Book): Result<List<ResolvedTrack>> = runCatching {
        val tracks = repository.getAudioTracks(book).getOrThrow()
        if (tracks.isEmpty()) error("Plex returned no tracks for ${book.title}")
        tracks.map { track ->
            val url = track.contentUrl ?: error("Plex track ${track.index} has no contentUrl")
            ResolvedTrack(
                index = track.index,
                title = track.title ?: track.fileName,
                durationMs = track.durationMs,
                url = url,
            )
        }
    }
}
