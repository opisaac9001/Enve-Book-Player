package com.enve.app.playback

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaConstants
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.repository.AggregatorRepository
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.BookExtrasDao
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.LastOpenedBookStore
import com.enve.core.data.local.decodeChapters
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.Chapter
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.provider.synthesizeChaptersFromTracks
import com.enve.engine.impl.R
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
@androidx.annotation.OptIn(UnstableApi::class)
class AutoMediaBrowserHelper @Inject constructor(
    @ApplicationContext private val context: Context,
    private val bookCacheDao: BookCacheDao,
    private val bookExtrasDao: BookExtrasDao,
    private val aggregatorRepository: AggregatorRepository,
    private val offlineDownloadManager: OfflineDownloadManager,
    private val autoArtworkCache: AutoArtworkCache,
    private val lastOpenedBookStore: LastOpenedBookStore,
) {

    companion object {
        const val ROOT_ID = "enve_root"
        const val SHELF_IN_PROGRESS = "enve_shelf_in_progress"
        const val SHELF_RECENT = "enve_shelf_recent"

        private const val BOOK_PREFIX = "book:"
        private const val TAG = "AutoMediaBrowser"
        private const val SHELF_LIMIT = 50
        private const val COVER_ITEM_TIMEOUT_MS = 3_000L

        fun cacheKeyFrom(mediaId: String): String? {
            if (!mediaId.startsWith(BOOK_PREFIX)) return null
            return mediaId.removePrefix(BOOK_PREFIX).substringBefore('#').takeIf { it.isNotBlank() }
        }

        fun mediaIdForCacheKey(cacheKey: String): String = "$BOOK_PREFIX$cacheKey"

        fun mediaIdForTrack(cacheKey: String, trackIndex: Int): String =
            "$BOOK_PREFIX$cacheKey#track:$trackIndex"
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
                shelfItem(
                    SHELF_IN_PROGRESS,
                    R.string.android_auto_continue_listening,
                    R.drawable.ic_car_continue,
                ),
                shelfItem(
                    SHELF_RECENT,
                    R.string.android_auto_recently_added,
                    R.drawable.ic_car_recent,
                ),
            )
            SHELF_IN_PROGRESS -> loadShelf { bookCacheDao.getInProgressAudiobooksOnce(SHELF_LIMIT) }
            SHELF_RECENT -> loadShelf { bookCacheDao.getRecentlyAddedAudiobooks(SHELF_LIMIT) }
            else -> {
                Log.w(TAG, "getChildren: unknown parentId='$parentId'")
                emptyList()
            }
        }
    }

    suspend fun getItem(mediaId: String): MediaItem? = withContext(Dispatchers.IO) {
        when (mediaId) {
            ROOT_ID -> buildRoot()
            SHELF_IN_PROGRESS -> shelfItem(
                SHELF_IN_PROGRESS,
                R.string.android_auto_continue_listening,
                R.drawable.ic_car_continue,
            )
            SHELF_RECENT -> shelfItem(
                SHELF_RECENT,
                R.string.android_auto_recently_added,
                R.drawable.ic_car_recent,
            )
            else -> cacheKeyFrom(mediaId)
                ?.let { bookCacheDao.getByCacheKey(it) }
                ?.toBook()
                ?.let { browseItemFor(it, artworkUriFor(it)) }
        }
    }

    data class ResolvedPlayback(
        val items: List<MediaItem>,
        val startIndex: Int,
        val startPositionMs: Long,
        val absoluteStartPositionMs: Long,
        val book: Book,
        val chapters: List<Chapter>,
        val providerSessionId: String?,
        val durationSec: Long,
    )

    private data class ProviderTracks(
        val tracks: List<AudioTrack>,
        val session: ProviderPlaybackSession?,
    )

    private data class SearchCandidate(
        val book: Book,
        val rank: Int,
    )

    suspend fun resolvePlaybackResumption(forPlayback: Boolean): ResolvedPlayback? = withContext(Dispatchers.IO) {
        val lastOpened = lastOpenedBookStore.lastOpenedBookKey.first()
            ?.let { bookCacheDao.getByCacheKey(it) }
        val cached = lastOpened ?: bookCacheDao.getInProgressAudiobooksOnce(1).firstOrNull()
            ?: return@withContext null
        resolveToPlayableItems(mediaIdForCacheKey(cached.cacheKey), forPlayback)
    }

    suspend fun resolveSessionRequest(mediaItem: MediaItem): ResolvedPlayback? {
        if (cacheKeyFrom(mediaItem.mediaId) != null) {
            return resolveToPlayableItems(mediaItem.mediaId, forPlayback = true)
        }
        if (!isVoiceSearchRequest(mediaItem)) return null

        val request = voiceSearchFrom(mediaItem)
        if (request.isEmpty) return resolvePlaybackResumption(forPlayback = true)
        val match = searchCandidates(request).firstOrNull()?.book
            ?: throw UnsupportedOperationException("No matching audiobook")
        return resolveToPlayableItems(mediaIdForCacheKey(match.uniqueKey), forPlayback = true)
    }

    suspend fun searchAudiobooks(query: String, page: Int, pageSize: Int): List<MediaItem> {
        val safePage = page.coerceAtLeast(0)
        val safePageSize = pageSize.coerceIn(1, 100)
        val from = safePage * safePageSize
        val matches = searchCandidates(VoiceAudiobookSearch.create(query, null, null))
            .drop(from)
            .take(safePageSize)
        return coverItems(matches.map { it.book })
    }

    suspend fun audiobookSearchCount(query: String): Int =
        searchCandidates(VoiceAudiobookSearch.create(query, null, null)).size

    suspend fun resolveToPlayableItems(
        mediaId: String,
        forPlayback: Boolean = true,
    ): ResolvedPlayback? = withContext(Dispatchers.IO) {
        val cacheKey = cacheKeyFrom(mediaId) ?: run {
            Log.w(TAG, "resolve: '$mediaId' has no $BOOK_PREFIX prefix")
            return@withContext null
        }
        val cached = bookCacheDao.getByCacheKey(cacheKey) ?: run {
            Log.w(TAG, "resolve: no cached book for cacheKey='$cacheKey'")
            return@withContext null
        }
        val cachedBook = cached.toBook()
        val storedChapters = bookExtrasDao.get(cached.cacheKey)
            ?.decodeChapters()
            .orEmpty()
        val book = if (cachedBook.chapters.isEmpty() && storedChapters.isNotEmpty()) {
            cachedBook.copy(chapters = storedChapters)
        } else {
            cachedBook
        }
        val localResumeMs = (cached.currentTime * 1000L).coerceAtLeast(0L)

        val offline = offlineTracks(book)
        if (offline.isNotEmpty()) {
            val chapters = book.chapters.ifEmpty {
                synthesizeChaptersFromTracks(offline, book.duration)
            }
            Log.i(TAG, "resolve: ${book.id} using ${offline.size} offline tracks resume=${localResumeMs}ms")
            return@withContext buildResolved(book, offline, localResumeMs, chapters, null)
        }

        val remote = providerTracks(book, forPlayback)
        if (remote.tracks.isEmpty()) {
            Log.w(TAG, "resolve: no playable tracks for ${book.source}/${book.id}")
            return@withContext null
        }
        val resumeMs = localResumeMs.takeIf { it > 0L }
            ?: remote.session?.serverCurrentTimeSec?.times(1000L)
            ?: 0L
        val chapters = remote.session?.chapters?.takeIf { it.isNotEmpty() }
            ?: book.chapters.takeIf { it.isNotEmpty() }
            ?: synthesizeChaptersFromTracks(remote.tracks, book.duration)
        Log.i(TAG, "resolve: ${book.id} using ${remote.tracks.size} provider tracks resume=${resumeMs}ms")
        buildResolved(book, remote.tracks, resumeMs, chapters, remote.session?.sessionId)
    }

    private suspend fun buildResolved(
        book: Book,
        tracks: List<AudioTrack>,
        resumeMs: Long,
        chapters: List<Chapter>,
        providerSessionId: String?,
    ): ResolvedPlayback {
        val artworkUri = artworkUriFor(book)
        val items = tracks.map { playableItem(book, it, artworkUri) }
        val (index, offsetMs) = startOffsetInTracks(tracks, resumeMs)
        val durationSec = book.duration.takeIf { it > 0L }
            ?: tracks.sumOf { it.durationMs.coerceAtLeast(0L) } / 1000L
        return ResolvedPlayback(
            items = items,
            startIndex = index,
            startPositionMs = offsetMs,
            absoluteStartPositionMs = resumeMs,
            book = book.copy(duration = durationSec),
            chapters = chapters,
            providerSessionId = providerSessionId,
            durationSec = durationSec,
        )
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

    private suspend fun loadShelf(query: suspend () -> List<CachedBook>): List<MediaItem> {
        val rows = try {
            query()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "shelf query failed", e)
            return emptyList()
        }
        return coverItems(rows.map { it.toBook() })
    }

    private suspend fun coverItems(books: List<Book>): List<MediaItem> = coroutineScope {
        books.map { book ->
            async {
                val artworkUri = withTimeoutOrNull(COVER_ITEM_TIMEOUT_MS) {
                    artworkUriFor(book)
                }
                browseItemFor(book, artworkUri)
            }
        }.awaitAll()
    }

    private suspend fun searchCandidates(search: VoiceAudiobookSearch): List<SearchCandidate> =
        withContext(Dispatchers.IO) {
            val query = search.title ?: search.query ?: search.creator ?: return@withContext emptyList()
            bookCacheDao.searchAudiobooksByMetadata(query).mapNotNull { cached ->
                val rank = search.rank(cached.title, cached.author, cached.narrator)
                if (rank >= VoiceAudiobookSearch.NO_MATCH) return@mapNotNull null
                SearchCandidate(cached.toBook(), rank)
            }.sortedWith(
                compareBy<SearchCandidate> { it.rank }
                    .thenByDescending { it.book.lastReadTime }
                    .thenByDescending { it.book.addedOn }
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

    private suspend fun artworkUriFor(book: Book): Uri? =
        autoArtworkCache.uriFor(book.id, book.uniqueKey, book.coverUrl)

    private fun shelfItem(id: String, titleResId: Int, artworkResId: Int): MediaItem = MediaItem.Builder()
        .setMediaId(id)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(context.getString(titleResId))
                .setIsBrowsable(true)
                .setIsPlayable(false)
                .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_AUDIO_BOOKS)
                .setArtworkUri(androidResourceUri(artworkResId))
                .setExtras(
                    Bundle().apply {
                        putInt(
                            MediaConstants.EXTRAS_KEY_CONTENT_STYLE_PLAYABLE,
                            MediaConstants.EXTRAS_VALUE_CONTENT_STYLE_GRID_ITEM,
                        )
                    }
                )
                .build()
        )
        .build()

    private fun androidResourceUri(resourceId: Int): Uri = Uri.Builder()
        .scheme("android.resource")
        .authority(context.resources.getResourcePackageName(resourceId))
        .appendPath(context.resources.getResourceTypeName(resourceId))
        .appendPath(context.resources.getResourceEntryName(resourceId))
        .build()

    private fun browseItemFor(book: Book, artworkUri: Uri? = null): MediaItem {
        val meta = MediaMetadata.Builder()
            .setTitle(book.title)
            .setArtist(book.author)
            .setIsBrowsable(false)
            .setIsPlayable(true)
            .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK)
            .setExtras(carMetadataExtras(book))
            .apply {
                artworkUri?.let(::setArtworkUri)
                if (book.duration > 0L) setDurationMs(book.duration * 1000L)
            }
            .build()
        return MediaItem.Builder()
            .setMediaId(mediaIdForCacheKey(book.uniqueKey))
            .setMediaMetadata(meta)
            .build()
    }

    private fun playableItem(book: Book, track: AudioTrack, artworkUri: Uri?): MediaItem {
        val meta = MediaMetadata.Builder()
            .setTitle(track.title?.takeIf { it.isNotBlank() } ?: book.title)
            .setArtist(book.author)
            .setAlbumTitle(book.title)
            .setIsBrowsable(false)
            .setIsPlayable(true)
            .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK)
            .setExtras(carMetadataExtras(book))
            .apply {
                artworkUri?.let(::setArtworkUri)
                if (track.durationMs > 0L) setDurationMs(track.durationMs)
            }
            .build()
        return MediaItem.Builder()
            .setMediaId(mediaIdForTrack(book.uniqueKey, track.index))
            .setUri(track.contentUrl.orEmpty())
            .setMediaMetadata(meta)
            .build()
    }

    private fun carMetadataExtras(book: Book): Bundle = Bundle().apply {
        putLong(
            MediaConstants.EXTRAS_KEY_DOWNLOAD_STATUS,
            if (book.isDownloaded) {
                MediaConstants.EXTRAS_VALUE_STATUS_DOWNLOADED
            } else {
                MediaConstants.EXTRAS_VALUE_STATUS_NOT_DOWNLOADED
            },
        )
        val progress = book.progress.toDouble()
        when {
            book.isFinished -> putInt(
                MediaConstants.EXTRAS_KEY_COMPLETION_STATUS,
                MediaConstants.EXTRAS_VALUE_COMPLETION_STATUS_FULLY_PLAYED,
            )
            progress > 0.0 -> {
                putInt(
                    MediaConstants.EXTRAS_KEY_COMPLETION_STATUS,
                    MediaConstants.EXTRAS_VALUE_COMPLETION_STATUS_PARTIALLY_PLAYED,
                )
                putDouble(MediaConstants.EXTRAS_KEY_COMPLETION_PERCENTAGE, progress)
            }
            else -> putInt(
                MediaConstants.EXTRAS_KEY_COMPLETION_STATUS,
                MediaConstants.EXTRAS_VALUE_COMPLETION_STATUS_NOT_PLAYED,
            )
        }
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

    private suspend fun providerTracks(book: Book, forPlayback: Boolean): ProviderTracks {
        val session = if (forPlayback) {
            try {
                aggregatorRepository.startPlaybackSession(book).getOrNull()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "startPlaybackSession failed for ${book.id}", e)
                null
            }
        } else {
            null
        }
        val fromSession = session?.audioTracks.orEmpty().filter { !it.contentUrl.isNullOrBlank() }
        if (fromSession.isNotEmpty()) return ProviderTracks(fromSession.sortedBy { it.index }, session)

        val fromTracks = try {
            aggregatorRepository.getAudioTracks(book).getOrNull().orEmpty()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "getAudioTracks failed for ${book.id}", e)
            emptyList()
        }
        return ProviderTracks(
            tracks = fromTracks.filter { !it.contentUrl.isNullOrBlank() }.sortedBy { it.index },
            session = session,
        )
    }
}
