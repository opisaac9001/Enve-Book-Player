package com.enve.app.playback

import android.content.Context
import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import android.net.Uri
import android.provider.MediaStore
import android.util.Log
import androidx.core.graphics.drawable.toBitmap
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.UnstableApi
import coil.ImageLoader
import coil.request.ImageRequest
import coil.request.SuccessResult
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.repository.AggregatorRepository
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayOutputStream
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
@androidx.annotation.OptIn(UnstableApi::class)
class AutoMediaBrowserHelper @Inject constructor(
    @ApplicationContext private val context: Context,
    private val bookCacheDao: BookCacheDao,
    private val aggregatorRepository: AggregatorRepository,
    private val offlineDownloadManager: OfflineDownloadManager,
    private val imageLoader: ImageLoader,
) {

    companion object {
        const val ROOT_ID = "enve_root"
        const val SHELF_IN_PROGRESS = "enve_shelf_in_progress"
        const val SHELF_RECENT = "enve_shelf_recent"

        private const val BOOK_PREFIX = "book:"
        private const val TAG = "AutoMediaBrowser"
        private const val SHELF_LIMIT = 50
        private const val COVER_TARGET_PX = 320
        private const val COVER_FETCH_TIMEOUT_MS = 2_500L

        fun cacheKeyFrom(mediaId: String): String? {
            if (!mediaId.startsWith(BOOK_PREFIX)) return null
            return mediaId.removePrefix(BOOK_PREFIX).substringBefore('#').takeIf { it.isNotBlank() }
        }

        fun mediaIdForCacheKey(cacheKey: String): String = "$BOOK_PREFIX$cacheKey"
    }

    fun buildRoot(): MediaItem = MediaItem.Builder()
        .setMediaId(ROOT_ID)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle("Enve")
                .setIsBrowsable(true)
                .setIsPlayable(false)
                .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_AUDIO_BOOKS)
                .build()
        )
        .build()

    suspend fun getChildren(parentId: String): List<MediaItem> = withContext(Dispatchers.IO) {
        when (parentId) {
            ROOT_ID -> listOf(
                shelfItem(SHELF_IN_PROGRESS, "Continue Listening"),
                shelfItem(SHELF_RECENT, "Recently Added"),
            )
            SHELF_IN_PROGRESS -> loadShelf { bookCacheDao.getInProgressAudiobooksOnce(SHELF_LIMIT) }
            SHELF_RECENT -> loadShelf { bookCacheDao.getRecentlyAddedAudiobooks(SHELF_LIMIT) }
            else -> {
                Log.w(TAG, "getChildren: unknown parentId='$parentId'")
                emptyList()
            }
        }
    }

    data class ResolvedPlayback(
        val items: List<MediaItem>,
        val startIndex: Int,
        val startPositionMs: Long,
    )

    private data class DownloadedCandidate(
        val book: Book,
        val downloadedAtEpochMs: Long,
        val rank: Int,
    )

    suspend fun resolvePlaybackResumption(): ResolvedPlayback? = withContext(Dispatchers.IO) {
        val cached = bookCacheDao.getInProgressAudiobooksOnce(1).firstOrNull()
            ?: bookCacheDao.getRecentlyAddedAudiobooks(1).firstOrNull()
            ?: return@withContext null
        resolveToPlayableItems(mediaIdForCacheKey(cached.cacheKey))
    }

    suspend fun resolveSessionRequest(mediaItem: MediaItem): ResolvedPlayback? {
        if (cacheKeyFrom(mediaItem.mediaId) != null) {
            return resolveToPlayableItems(mediaItem.mediaId)
        }
        if (!isVoiceSearchRequest(mediaItem)) return null

        val request = voiceSearchFrom(mediaItem)
        if (request.isEmpty) return resolvePlaybackResumption()
        val match = downloadedCandidates(request).firstOrNull()?.book
            ?: throw UnsupportedOperationException("No matching downloaded audiobook")
        return resolveToPlayableItems(mediaIdForCacheKey(match.uniqueKey))
    }

    suspend fun searchDownloadedAudiobooks(query: String, page: Int, pageSize: Int): List<MediaItem> {
        val safePage = page.coerceAtLeast(0)
        val safePageSize = pageSize.coerceIn(1, 100)
        val from = safePage * safePageSize
        return downloadedCandidates(VoiceAudiobookSearch.create(query, null, null))
            .drop(from)
            .take(safePageSize)
            .map { browseItemFor(it.book) }
    }

    suspend fun downloadedAudiobookSearchCount(query: String): Int =
        downloadedCandidates(VoiceAudiobookSearch.create(query, null, null)).size

    suspend fun resolveToPlayableItems(mediaId: String): ResolvedPlayback? = withContext(Dispatchers.IO) {
        val cacheKey = cacheKeyFrom(mediaId) ?: run {
            Log.w(TAG, "resolve: '$mediaId' has no $BOOK_PREFIX prefix")
            return@withContext null
        }
        val cached = bookCacheDao.getByCacheKey(cacheKey) ?: run {
            Log.w(TAG, "resolve: no cached book for cacheKey='$cacheKey'")
            return@withContext null
        }
        val book = cached.toBook()
        val resumeMs = (cached.currentTime * 1000L).coerceAtLeast(0L)

        val offline = offlineTracks(book)
        if (offline.isNotEmpty()) {
            Log.i(TAG, "resolve: ${book.id} using ${offline.size} offline tracks resume=${resumeMs}ms")
            return@withContext buildResolved(book, offline, resumeMs)
        }

        val remote = providerTracks(book)
        if (remote.isEmpty()) {
            Log.w(TAG, "resolve: no playable tracks for ${book.source}/${book.id}")
            return@withContext null
        }
        Log.i(TAG, "resolve: ${book.id} using ${remote.size} provider tracks resume=${resumeMs}ms")
        buildResolved(book, remote, resumeMs)
    }

    private fun buildResolved(book: Book, tracks: List<AudioTrack>, resumeMs: Long): ResolvedPlayback {
        val items = tracks.map { playableItem(book, it) }
        val (index, offsetMs) = startOffsetInTracks(tracks, resumeMs)
        return ResolvedPlayback(items, index, offsetMs)
    }

    private fun startOffsetInTracks(tracks: List<AudioTrack>, resumeMs: Long): Pair<Int, Long> {
        if (tracks.size <= 1 || resumeMs <= 0L) return 0 to resumeMs.coerceAtLeast(0L)
        var running = 0L
        tracks.forEachIndexed { index, track ->
            val duration = track.durationMs.coerceAtLeast(0L)
            if (duration > 0L && resumeMs < running + duration) {
                return index to (resumeMs - running).coerceAtLeast(0L)
            }
            running += duration
        }
        val lastIdx = tracks.lastIndex.coerceAtLeast(0)
        return lastIdx to (tracks.getOrNull(lastIdx)?.durationMs?.coerceAtLeast(0L) ?: 0L)
    }

    private suspend fun loadShelf(query: suspend () -> List<com.enve.core.data.local.CachedBook>): List<MediaItem> {
        val rows = try {
            query()
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            Log.e(TAG, "shelf query failed", t)
            return emptyList()
        }
        return coroutineScope {
            rows.map { cached ->
                async {
                    val book = cached.toBook()
                    browseItemFor(book, fetchCoverBytes(book.coverUrl))
                }
            }.awaitAll()
        }
    }

    private suspend fun downloadedCandidates(search: VoiceAudiobookSearch): List<DownloadedCandidate> =
        withContext(Dispatchers.IO) {
            val manifests = offlineDownloadManager.listDownloadedManifests()
                .filter { offlineDownloadManager.isDownloaded(it.bookId) }
            if (manifests.isEmpty()) return@withContext emptyList()

            val cachedByID = manifests
                .map { it.bookId }
                .distinct()
                .chunked(500)
                .flatMap { bookCacheDao.getAudiobooksByIds(it) }
                .associateBy { it.id }

            manifests.mapNotNull { manifest ->
                val cached = cachedByID[manifest.bookId] ?: return@mapNotNull null
                val rank = search.rank(manifest.title, manifest.author, cached.narrator)
                if (rank >= VoiceAudiobookSearch.NO_MATCH) return@mapNotNull null
                DownloadedCandidate(cached.toBook(), manifest.downloadedAtEpochMs, rank)
            }.sortedWith(
                compareBy<DownloadedCandidate> { it.rank }
                    .thenByDescending { it.downloadedAtEpochMs }
                    .thenBy { it.book.title.lowercase() }
            )
        }

    private fun isVoiceSearchRequest(mediaItem: MediaItem): Boolean {
        val request = mediaItem.requestMetadata
        val extras = request.extras
        return request.searchQuery != null ||
            extras?.containsKey(MediaStore.EXTRA_MEDIA_TITLE) == true ||
            extras?.containsKey(MediaStore.EXTRA_MEDIA_ALBUM) == true ||
            extras?.containsKey(MediaStore.EXTRA_MEDIA_ARTIST) == true
    }

    private fun voiceSearchFrom(mediaItem: MediaItem): VoiceAudiobookSearch {
        val request = mediaItem.requestMetadata
        val extras = request.extras
        return VoiceAudiobookSearch.create(
            query = request.searchQuery,
            title = extras?.getString(MediaStore.EXTRA_MEDIA_TITLE)
                ?: extras?.getString(MediaStore.EXTRA_MEDIA_ALBUM),
            creator = extras?.getString(MediaStore.EXTRA_MEDIA_ARTIST),
        )
    }

    private suspend fun fetchCoverBytes(url: String?): ByteArray? {
        if (url.isNullOrBlank()) return null
        return withTimeoutOrNull(COVER_FETCH_TIMEOUT_MS) {
            try {
                val result = imageLoader.execute(
                    ImageRequest.Builder(context)
                        .data(url)
                        .size(COVER_TARGET_PX)
                        .allowHardware(false)
                        .build()
                )
                if (result !is SuccessResult) return@withTimeoutOrNull null
                val bitmap = (result.drawable as? BitmapDrawable)?.bitmap
                    ?: result.drawable.toBitmap()
                ByteArrayOutputStream().use { out ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
                    out.toByteArray()
                }
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                Log.w(TAG, "cover fetch failed for $url", t)
                null
            }
        }
    }

    private fun shelfItem(id: String, title: String): MediaItem = MediaItem.Builder()
        .setMediaId(id)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(title)
                .setIsBrowsable(true)
                .setIsPlayable(false)
                .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_AUDIO_BOOKS)
                .build()
        )
        .build()

    private fun browseItemFor(book: Book, artworkBytes: ByteArray? = null): MediaItem {
        val artworkUri = offlineDownloadManager.localCoverUri(book.id) ?: book.coverUrl
        val meta = MediaMetadata.Builder()
            .setTitle(book.title)
            .setArtist(book.author)
            .setIsBrowsable(false)
            .setIsPlayable(true)
            .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK)
            .apply {
                artworkUri?.takeIf { it.isNotBlank() }?.let { setArtworkUri(Uri.parse(it)) }
                artworkBytes?.let { setArtworkData(it, MediaMetadata.PICTURE_TYPE_FRONT_COVER) }
                if (book.duration > 0L) setDurationMs(book.duration * 1000L)
            }
            .build()
        return MediaItem.Builder()
            .setMediaId(mediaIdForCacheKey(book.uniqueKey))
            .setMediaMetadata(meta)
            .build()
    }

    private fun playableItem(book: Book, track: AudioTrack): MediaItem {
        val artworkUri = offlineDownloadManager.localCoverUri(book.id) ?: book.coverUrl
        val meta = MediaMetadata.Builder()
            .setTitle(track.title?.takeIf { it.isNotBlank() } ?: book.title)
            .setArtist(book.author)
            .setAlbumTitle(book.title)
            .setIsBrowsable(false)
            .setIsPlayable(true)
            .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK)
            .apply {
                artworkUri?.takeIf { it.isNotBlank() }?.let { setArtworkUri(Uri.parse(it)) }
                if (track.durationMs > 0L) setDurationMs(track.durationMs)
            }
            .build()
        return MediaItem.Builder()
            .setMediaId(mediaIdForCacheKey(book.uniqueKey))
            .setUri(track.contentUrl.orEmpty())
            .setMediaMetadata(meta)
            .build()
    }

    private fun offlineTracks(book: Book): List<AudioTrack> =
        offlineDownloadManager.localTracks(book.id)
            .orEmpty()
            .mapIndexed { index, track ->
                AudioTrack(
                    index = index,
                    fileName = track.title ?: "Track ${index + 1}",
                    title = track.title,
                    durationMs = track.durationMs,
                    contentUrl = track.uri,
                )
            }

    private suspend fun providerTracks(book: Book): List<AudioTrack> {
        val session = try {
            aggregatorRepository.startPlaybackSession(book).getOrNull()
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            Log.e(TAG, "startPlaybackSession failed for ${book.id}", t)
            null
        }
        val fromSession = session?.audioTracks.orEmpty().filter { !it.contentUrl.isNullOrBlank() }
        if (fromSession.isNotEmpty()) return fromSession.sortedBy { it.index }

        val fromTracks = try {
            aggregatorRepository.getAudioTracks(book).getOrNull().orEmpty()
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            Log.e(TAG, "getAudioTracks failed for ${book.id}", t)
            emptyList()
        }
        return fromTracks.filter { !it.contentUrl.isNullOrBlank() }.sortedBy { it.index }
    }
}
