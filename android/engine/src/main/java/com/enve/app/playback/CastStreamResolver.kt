package com.enve.app.playback

import android.os.Bundle
import androidx.media3.common.MediaItem
import com.enve.app.data.offline.AudiobookTrackResolver
import com.enve.audiobookshelf.AudiobookshelfRepository
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.BookSource
import com.enve.core.data.playback.CastCompatibility
import com.enve.core.data.remote.ConnectionScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.EmptyCoroutineContext

internal const val CAST_ORIGINAL_URI_EXTRA = "enve.cast.originalUri"

@Singleton
class CastStreamResolver @Inject constructor(
    private val bookCacheDao: BookCacheDao,
    private val trackResolvers: Map<BookSource, @JvmSuppressWildcards AudiobookTrackResolver>,
    private val audiobookshelfRepository: AudiobookshelfRepository,
) {
    suspend fun resolve(mediaItems: List<MediaItem>): List<MediaItem>? {
        if (mediaItems.isEmpty() || mediaItems.any { !it.hasLocalUri() }) return null
        val cacheKeys = mediaItems.mapNotNull { AutoMediaBrowserHelper.cacheKeyFrom(it.mediaId) }.toSet()
        if (cacheKeys.size != 1) return null

        val cached = withContext(Dispatchers.IO) {
            bookCacheDao.getByCacheKey(cacheKeys.single())
        } ?: return null
        val book = cached.toBook()
        if (!CastCompatibility.canCastStream(book.source)) return null
        val resolver = trackResolvers[book.source] ?: return null
        val connectionContext = book.connectionId
            ?.let(ConnectionScope::asContextElement)
            ?: EmptyCoroutineContext

        return withContext(Dispatchers.IO + connectionContext) {
            val tracks = resolver.resolveTracks(book).getOrElse { error ->
                if (error is CancellationException) throw error
                return@withContext null
            }.sortedBy { it.index }
            if (tracks.size != mediaItems.size) return@withContext null

            val authToken = if (book.source == BookSource.AUDIOBOOKSHELF) {
                audiobookshelfRepository.currentAccessToken()
            } else {
                null
            }
            mediaItems.zip(tracks).map { (localItem, track) ->
                val localUri = localItem.localConfiguration?.uri?.toString()
                    ?: return@withContext null
                val castUrl = AudioPlaybackManager.withAuthToken(track.url, authToken)
                if (!CastCompatibility.receiverCanValidate(castUrl)) return@withContext null
                val extras = Bundle(localItem.requestMetadata.extras ?: Bundle.EMPTY).apply {
                    putString(CAST_ORIGINAL_URI_EXTRA, localUri)
                }
                localItem.buildUpon()
                    .setUri(castUrl)
                    .setMimeType(AudioPlaybackManager.guessMimeType(castUrl))
                    .setRequestMetadata(
                        localItem.requestMetadata.buildUpon()
                            .setExtras(extras)
                            .build(),
                    )
                    .build()
            }
        }
    }

    private fun MediaItem.hasLocalUri(): Boolean {
        val scheme = localConfiguration?.uri?.scheme?.lowercase()
        return scheme == "file" || scheme == "content"
    }
}
