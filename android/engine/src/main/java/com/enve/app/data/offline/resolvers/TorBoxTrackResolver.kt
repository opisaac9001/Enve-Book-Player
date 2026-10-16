package com.enve.app.data.offline.resolvers

import com.enve.app.data.offline.AudiobookTrackResolver
import com.enve.app.data.offline.ResolvedTrack
import com.enve.app.data.provider.TorBoxProviderAdapter
import com.enve.core.data.model.Book
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.util.runSuspendCatching
import kotlinx.coroutines.withContext
import javax.inject.Inject

class TorBoxTrackResolver @Inject constructor(
    private val adapter: TorBoxProviderAdapter,
) : AudiobookTrackResolver {
    override suspend fun resolveTracks(book: Book): Result<List<ResolvedTrack>> = runSuspendCatching {
        withContext(ConnectionScope.asContextElement(book.connectionId)) {
            val tracks = adapter.startPlaybackSession(book.copy(libraryId = book.libraryId?.substringAfter("::")))
                .getOrThrow().audioTracks
            check(tracks.isNotEmpty()) { "TorBox returned no audio tracks. Refresh the library and try again." }
            tracks.map { track ->
                val url = track.contentUrl?.takeIf { it.isNotBlank() }
                    ?: error("TorBox returned an audio track without a download link.")
                ResolvedTrack(track.index, track.title ?: track.fileName, track.durationMs, url)
            }
        }
    }
}
