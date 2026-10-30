package com.enve.app.data.offline.resolvers

import com.enve.app.data.offline.AudiobookTrackResolver
import com.enve.app.data.offline.ResolvedTrack
import com.enve.app.data.provider.JellyfinProviderAdapter
import com.enve.core.data.model.Book
import javax.inject.Inject

class JellyfinTrackResolver @Inject constructor(
    private val provider: JellyfinProviderAdapter,
) : AudiobookTrackResolver {
    override suspend fun resolveTracks(book: Book): Result<List<ResolvedTrack>> = runCatching {
        val tracks = provider.getAudioTracks(book).getOrThrow()
        check(tracks.isNotEmpty()) { "Jellyfin returned no audio tracks" }
        tracks.map { track ->
            val url = track.contentUrl?.takeIf { it.isNotBlank() }
                ?: error("Jellyfin track ${track.index} has no download URL")
            ResolvedTrack(
                index = track.index,
                title = track.title ?: track.fileName,
                durationMs = track.durationMs,
                url = url,
                sizeBytes = track.fileSizeBytes,
                assetId = track.fileId,
            )
        }
    }
}
