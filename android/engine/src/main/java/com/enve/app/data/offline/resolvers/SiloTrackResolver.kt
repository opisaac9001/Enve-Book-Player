package com.enve.app.data.offline.resolvers

import com.enve.app.data.offline.AudiobookTrackResolver
import com.enve.app.data.offline.ResolvedTrack
import com.enve.core.data.model.Book
import com.enve.core.data.util.runSuspendCatching
import com.enve.silo.SiloRepository
import javax.inject.Inject

class SiloTrackResolver @Inject constructor(private val repository: SiloRepository) : AudiobookTrackResolver {
    override suspend fun resolveTracks(book: Book): Result<List<ResolvedTrack>> = runSuspendCatching {
        val download = repository.getAudioDownload(book).getOrThrow()
        download.tracks.map { track ->
            ResolvedTrack(
                index = track.index,
                title = track.title ?: track.fileName,
                durationMs = track.durationMs,
                url = checkNotNull(track.contentUrl),
                httpHeaders = download.headers,
                sizeBytes = track.fileSizeBytes,
                assetId = track.fileId,
            )
        }
    }
}
