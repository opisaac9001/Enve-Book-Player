package com.enve.app.data.offline.resolvers

import com.enve.core.data.model.Book
import com.enve.app.data.offline.AudiobookTrackResolver
import com.enve.app.data.offline.ResolvedTrack
import com.enve.app.data.repository.GrimmoryRepository
import javax.inject.Inject

class GrimmoryTrackResolver @Inject constructor(
    private val repository: GrimmoryRepository,
) : AudiobookTrackResolver {

    override suspend fun resolveTracks(book: Book): Result<List<ResolvedTrack>> = runCatching {
        val info = repository.getAudiobookInfo(book.id).getOrNull()
        val tracks = info?.tracks.orEmpty()

        if (tracks.isNotEmpty()) {
            tracks.mapIndexed { ordinal, track ->
                val resolvedIndex = track.index.takeIf { it >= 0 } ?: ordinal
                ResolvedTrack(
                    index = resolvedIndex,
                    title = track.title ?: track.fileName,
                    durationMs = track.durationMs ?: 0L,
                    url = repository.getTrackStreamUrl(book.id, resolvedIndex),
                )
            }
        } else {
            listOf(
                ResolvedTrack(
                    index = 0,
                    title = book.title,
                    durationMs = book.duration * 1000,
                    url = repository.getStreamUrl(book.id),
                )
            )
        }
    }
}
