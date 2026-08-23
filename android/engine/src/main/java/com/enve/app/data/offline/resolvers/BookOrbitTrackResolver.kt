package com.enve.app.data.offline.resolvers

import com.enve.app.data.offline.AudiobookTrackResolver
import com.enve.app.data.offline.ResolvedTrack
import com.enve.bookorbit.BookOrbitRepository
import com.enve.core.data.model.Book
import javax.inject.Inject

class BookOrbitTrackResolver @Inject constructor(
    private val repository: BookOrbitRepository,
) : AudiobookTrackResolver {
    override suspend fun resolveTracks(book: Book): Result<List<ResolvedTrack>> = runCatching {
        val tracks = repository.getAudioTracks(book).getOrThrow()
        if (tracks.isEmpty()) error("BookOrbit returned no tracks for ${book.title}")
        tracks.map { track ->
            val fileId = track.fileId?.toIntOrNull() ?: error("BookOrbit track ${track.index} has no file id")
            ResolvedTrack(
                index = track.index,
                title = track.title ?: track.fileName,
                durationMs = track.durationMs,
                url = repository.getDownloadUrl(fileId),
            )
        }
    }
}
