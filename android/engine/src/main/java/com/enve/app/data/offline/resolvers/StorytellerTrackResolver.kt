package com.enve.app.data.offline.resolvers

import com.enve.core.data.model.Book
import com.enve.app.data.offline.AudiobookTrackResolver
import com.enve.app.data.offline.ResolvedTrack
import com.enve.storyteller.StorytellerRepository
import javax.inject.Inject

class StorytellerTrackResolver @Inject constructor(
    private val repository: StorytellerRepository,
) : AudiobookTrackResolver {

    override suspend fun resolveTracks(book: Book): Result<List<ResolvedTrack>> = runCatching {
        val session = repository.startPlaybackSession(book).getOrThrow()
        val tracks = session.audioTracks
        if (tracks.isEmpty()) error("Storyteller manifest has no audio tracks for ${book.title}")
        tracks.mapIndexed { index, track ->
            val url = track.contentUrl?.takeIf { it.isNotBlank() }
                ?: error("Storyteller track ${track.fileName} is missing a download URL")
            ResolvedTrack(
                index = track.index.takeIf { it >= 0 } ?: index,
                title = track.title ?: track.fileName,
                durationMs = track.durationMs,
                url = url,
            )
        }
    }
}
