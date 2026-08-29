package com.enve.app.playback

import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.offline.OfflineTrackInfo
import com.enve.app.data.repository.AggregatorRepository
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.app.readium.ReadAloudCheckpointRepository
import com.enve.app.readium.ReadAloudPlaybackCoordinator
import com.enve.audiobookshelf.AudiobookshelfRepository
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.BookExtras
import com.enve.core.data.local.BookExtrasDao
import com.enve.core.data.local.LastOpenedBookStore
import com.enve.core.data.local.decodeChapters
import com.enve.core.data.local.encodeChaptersJson
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.provider.synthesizeChaptersFromTracks
import com.enve.core.data.remote.ConnectionScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.EmptyCoroutineContext

@Singleton
class PlaybackStarter @Inject constructor(
    private val grimmory: GrimmoryRepository,
    private val aggregator: AggregatorRepository,
    private val offline: OfflineDownloadManager,
    private val bookCache: BookCacheDao,
    private val audioManager: AudioPlaybackManager,
    private val sessionService: PlayerSessionService,
    private val chapterStore: PlaybackChapterStore,
    private val absRepository: AudiobookshelfRepository,
    private val bookExtras: BookExtrasDao,
    private val lastOpenedBookStore: LastOpenedBookStore,
    private val readAloudCheckpoints: ReadAloudCheckpointRepository,
    private val readAloudPlayback: ReadAloudPlaybackCoordinator,
) {

    suspend fun start(book: Book): Boolean {
        val scoped = book.connectionId?.let { ConnectionScope.asContextElement(it) } ?: EmptyCoroutineContext
        return withContext(scoped) {
            readAloudPlayback.stopActiveAndAwait()
            readAloudCheckpoints.flushPending()
            val cached = withContext(Dispatchers.IO) { bookCache.getByCacheKey(book.uniqueKey)?.toBook() }
            val base = withCachedChapters(cached ?: book)

            offline.ensureCoverCached(base)
            val offlineCover = offline.localCoverUri(base.id) ?: offline.getManifest(base.id)?.coverUrl
            val resolved = if (offlineCover != null) base.copy(coverUrl = offlineCover) else base

            val mediaId = AutoMediaBrowserHelper.mediaIdForCacheKey(resolved.uniqueKey)
            val startSec = localStartSeconds(resolved)

            val localTracks = offline.localTracks(resolved.id)
            val started = when {
                !localTracks.isNullOrEmpty() -> {
                    startOffline(resolved, localTracks, startSec, mediaId)
                    true
                }
                resolved.source != BookSource.GRIMMORY -> startProvider(resolved, startSec, mediaId)
                else -> {
                    startGrimmory(resolved, startSec, mediaId)
                    true
                }
            }
            if (started) lastOpenedBookStore.record(resolved)
            started
        }
    }

    private suspend fun withCachedChapters(book: Book): Book {
        if (book.chapters.isNotEmpty()) return book
        val chapters = withContext(Dispatchers.IO) {
            bookExtras.get(book.uniqueKey)?.decodeChapters()?.takeIf { it.isNotEmpty() }
        } ?: return book
        return book.copy(chapters = chapters)
    }

    private suspend fun startOffline(book: Book, tracks: List<OfflineTrackInfo>, startSec: Long, mediaId: String) {
        withContext(Dispatchers.IO) {
            val rows = bookCache.updateDownloadedStatus(book.id, book.connectionId, true, System.currentTimeMillis())
            if (rows == 0) bookCache.updateDownloadedStatusById(book.id, true, System.currentTimeMillis())
        }
        val durationSec = when {
            book.duration > 0L -> book.duration
            tracks.sumOf { it.durationMs } > 0L -> tracks.sumOf { it.durationMs } / 1000L
            else -> 0L
        }
        storeChapters(book, book.chapters.ifEmpty { synthesize(tracks.map { it.title }, tracks.map { it.durationMs }) })
        if (tracks.size > 1) {
            audioManager.playMultiTrack(
                tracks = tracks.map { AudioPlaybackManager.TrackInfo(it.uri, it.title, it.durationMs) },
                bookId = book.id, title = book.title, author = book.author, coverUrl = book.coverUrl,
                startPositionMs = startSec * 1000, mediaId = mediaId,
            )
        } else {
            audioManager.play(
                streamUrl = tracks.first().uri, bookId = book.id, title = book.title, author = book.author,
                coverUrl = book.coverUrl, startPositionMs = startSec * 1000, mediaId = mediaId,
            )
        }
        sessionService.start(book.copy(duration = durationSec), startSec, durationSec)
    }

    private suspend fun startGrimmory(book: Book, startSec: Long, mediaId: String) {
        val info = grimmory.getAudiobookInfo(book.id).getOrNull()
        val durationSec = (info?.durationMs ?: (book.duration * 1000)) / 1000
        val tracks = info?.tracks
        val audioTracks = tracks?.mapIndexed { i, t ->
            com.enve.core.data.model.AudioTrack(
                index = t.index.takeIf { it >= 0 } ?: i,
                fileName = t.fileName ?: t.title ?: "Track ${i + 1}",
                title = t.title ?: t.fileName,
                durationMs = t.durationMs ?: 0L,
                fileSizeBytes = t.fileSizeBytes ?: 0L,
                cumulativeStartMs = t.cumulativeStartMs ?: 0L,
            )
        }.orEmpty()
        val chapters = info?.chapters?.mapIndexed { i, ch ->
            Chapter(
                index = ch.index.takeIf { it >= 0 } ?: i,
                title = ch.title ?: "Chapter ${i + 1}",
                startTime = ch.startTimeMs / 1000, endTime = ch.endTimeMs / 1000,
            )
        }?.ifEmpty { synthesizeChaptersFromTracks(audioTracks, durationSec) } ?: book.chapters
        storeChapters(book, chapters)
        if (tracks != null && tracks.size > 1) {
            audioManager.playMultiTrack(
                tracks = tracks.mapIndexed { i, t ->
                    AudioPlaybackManager.TrackInfo(
                        url = grimmory.getTrackStreamUrl(book.id, t.index.takeIf { it >= 0 } ?: i),
                        title = t.title ?: t.fileName, durationMs = t.durationMs ?: 0L,
                    )
                },
                bookId = book.id, title = book.title, author = book.author, coverUrl = book.coverUrl,
                startPositionMs = startSec * 1000, mediaId = mediaId,
            )
        } else {
            audioManager.play(
                streamUrl = grimmory.getStreamUrl(book.id), bookId = book.id, title = book.title,
                author = book.author, coverUrl = book.coverUrl, startPositionMs = startSec * 1000, mediaId = mediaId,
            )
        }
        sessionService.start(book.copy(duration = durationSec), startSec, durationSec)
    }

    private suspend fun startProvider(book: Book, startSec: Long, mediaId: String): Boolean {
        val session = aggregator.startPlaybackSession(book).getOrNull()
        val tracks = (session?.audioTracks?.takeIf { it.isNotEmpty() }
            ?: aggregator.getAudioTracks(book).getOrElse { book.audioTracks })
            .filter { !it.contentUrl.isNullOrBlank() }
            .sortedBy { it.index }
        if (tracks.isEmpty()) return false

        val durationSec = when {
            book.duration > 0 -> book.duration
            tracks.sumOf { it.durationMs } > 0L -> tracks.sumOf { it.durationMs } / 1000L
            else -> 0L
        }
        val effectiveStart = if (startSec > 0L) startSec else (session?.serverCurrentTimeSec ?: 0L)
        val embedded = if (tracks.size == 1) embeddedChapters(book) else null
        val chapters = session?.chapters?.takeIf { it.isNotEmpty() }
            ?: book.chapters.takeIf { it.isNotEmpty() }
            ?: embedded
            ?: synthesize(tracks.map { it.title ?: it.fileName }, tracks.map { it.durationMs })
        storeChapters(book, chapters)

        val castToken = if (book.source == BookSource.AUDIOBOOKSHELF) absRepository.currentAccessToken() else null

        if (tracks.size > 1) {
            audioManager.playMultiTrack(
                tracks = tracks.map { AudioPlaybackManager.TrackInfo(it.contentUrl.orEmpty(), it.title ?: it.fileName, it.durationMs) },
                bookId = book.id, title = book.title, author = book.author, coverUrl = book.coverUrl,
                startPositionMs = effectiveStart * 1000, mediaId = mediaId, authToken = castToken,
            )
        } else {
            audioManager.play(
                streamUrl = tracks.first().contentUrl.orEmpty(), bookId = book.id, title = book.title,
                author = book.author, coverUrl = book.coverUrl, startPositionMs = effectiveStart * 1000,
                mediaId = mediaId, authToken = castToken,
            )
        }
        sessionService.start(book.copy(duration = durationSec), effectiveStart, durationSec, session?.sessionId)
        return true
    }

    private suspend fun embeddedChapters(book: Book): List<Chapter>? =
        aggregator.fetchEmbeddedChapters(book).getOrNull()?.takeIf { it.isNotEmpty() }

    private suspend fun storeChapters(book: Book, chapters: List<Chapter>) {
        chapterStore.set(book.uniqueKey, book.id, chapters, book.title, book.author, book.coverUrl)
        if (chapters.isEmpty()) return
        withContext(Dispatchers.IO) {
            val existing = bookExtras.get(book.uniqueKey)
            bookExtras.upsert(
                BookExtras(
                    cacheKey = book.uniqueKey,
                    chaptersJson = encodeChaptersJson(chapters),
                    audioTracksJson = existing?.audioTracksJson ?: "[]",
                    updatedAt = System.currentTimeMillis(),
                ),
            )
        }
    }

    private fun synthesize(titles: List<String?>, durationsMs: List<Long>): List<Chapter> {
        if (durationsMs.size <= 1) return emptyList()
        var offsetMs = 0L
        return durationsMs.mapIndexed { i, durMs ->
            val startSec = offsetMs / 1000
            offsetMs += durMs
            Chapter(
                index = i,
                title = titles.getOrNull(i)?.ifBlank { null } ?: "Chapter ${i + 1}",
                startTime = startSec, endTime = offsetMs / 1000,
            )
        }
    }

    private fun localStartSeconds(book: Book): Long = when {
        book.currentTime > 0L -> book.currentTime
        book.duration > 0L && book.readProgress > 0f -> (book.readProgress * book.duration).toLong()
        else -> 0L
    }
}
