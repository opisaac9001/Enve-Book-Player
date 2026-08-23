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
