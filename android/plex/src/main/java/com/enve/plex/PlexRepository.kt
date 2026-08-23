package com.enve.plex

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.provider.synthesizeChaptersFromTracks
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.util.runSuspendCatching
import com.enve.plex.api.PlexApi
import com.enve.plex.dto.PlexChapter
import com.enve.plex.dto.PlexMetadata
import com.enve.plex.dto.PlexSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PlexRepository @Inject constructor(
    private val api: PlexApi,
    private val prefs: PreferencesManager,
    private val connectionRegistry: ConnectionRegistry,
    private val vault: CredentialVault,
) {

    private fun scoped(): Pair<String, String?> {
        connectionRegistry.getScopedConnectionSync()?.let { connection ->
            val token = vault.get(CredentialVault.accessTokenKey(connection.id))
                ?: prefs.getAccessTokenSync()
            return connection.serverUrl.trimEnd('/') to token
        }
        return (prefs.getServerUrlSync()?.trimEnd('/') ?: "") to prefs.getAccessTokenSync()
    }

    suspend fun getLibraries(): Result<List<Library>> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            val resp = api.getSections()
            if (!resp.isSuccessful) error("Plex sections HTTP ${resp.code()}")
            val sections = resp.body()?.mediaContainer?.directory.orEmpty()
            sections
                .filter { it.isAudiobookSection() }
                .map { it.toLibrary() }
        }
    }

    suspend fun getBooks(libraryId: String?): Result<List<Book>> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            val (serverUrl, _) = scoped()
            if (libraryId.isNullOrBlank()) {

                val libs = getLibraries().getOrThrow()
                libs.flatMap { fetchAllBooks(it.id, serverUrl) }
            } else {
                fetchAllBooks(libraryId, serverUrl)
            }
        }
    }

    suspend fun getRecentlyAdded(): Result<List<Book>> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            val (serverUrl, _) = scoped()
            val libs = getLibraries().getOrThrow()
            libs.flatMap { fetchAllBooks(it.id, serverUrl, sort = "addedAt:desc", limit = 30) }
                .sortedByDescending { it.addedOn }
                .take(50)
        }
    }

    suspend fun getStreamUrl(bookId: String): String? = withContext(Dispatchers.IO) {
        val (serverUrl, token) = scoped()
        val resp = api.getMetadata(bookId)
        if (!resp.isSuccessful) error("Plex metadata HTTP ${resp.code()}")
        val metadata = resp.body()?.mediaContainer?.metadata?.firstOrNull()
            ?: return@withContext null
        val partKey = firstPlayablePartKey(metadata) ?: return@withContext null
        buildStreamUrl(serverUrl, partKey, token)
    }

    private suspend fun firstPlayablePartKey(metadata: PlexMetadata): String? {

        metadata.media.firstOrNull()?.part?.firstOrNull()?.key?.let { return it }
        if (metadata.type == "album") {
            val resp = api.getMetadataChildren(metadata.ratingKey)
            if (!resp.isSuccessful) error("Plex children HTTP ${resp.code()}")
            val tracks = resp.body()?.mediaContainer?.metadata.orEmpty()
            return tracks.firstOrNull()?.media?.firstOrNull()?.part?.firstOrNull()?.key
        }
        return null
    }

    private fun buildStreamUrl(serverUrl: String, partKey: String, token: String?): String {
        val base = serverUrl.trimEnd('/').toHttpUrlOrNull()
            ?: error("Invalid Plex server URL")
        val rawPart = partKey.trim()
        val resolved = when {
            rawPart.startsWith("http://", ignoreCase = true) ||
                rawPart.startsWith("https://", ignoreCase = true) -> rawPart.toHttpUrlOrNull()
            rawPart.startsWith("/") -> base.resolve(rawPart)
            else -> base.resolve("/$rawPart")
        } ?: error("Invalid Plex part URL")

        return resolved.newBuilder()
            .removeAllQueryParameters("X-Plex-Token")
            .removeAllQueryParameters("download")
            .apply {
                token?.takeIf { it.isNotBlank() }?.let { addQueryParameter("X-Plex-Token", it) }
                addQueryParameter("download", "0")
            }
            .build()
            .toString()
    }

    suspend fun syncAudiobookProgress(
        book: Book,
        currentTimeSec: Long,
        progressFraction: Float,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            if (progressFraction >= 0.99f) {

                val resp = api.scrobble(ratingKey = book.id)
                if (!resp.isSuccessful) error("Plex scrobble HTTP ${resp.code()}")
            } else {
                val resp = api.reportProgress(
                    ratingKey = book.id,
                    timeMs = currentTimeSec * 1000L,
                    state = "stopped",
                )
                if (!resp.isSuccessful) error("Plex progress HTTP ${resp.code()}")
            }
        }
    }

    suspend fun fetchAudiobookProgress(book: Book): Result<SyncSnapshot?> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            val resp = api.getMetadata(book.id)
            if (!resp.isSuccessful) error("Plex metadata HTTP ${resp.code()}")
            val metadata = resp.body()?.mediaContainer?.metadata?.firstOrNull()
                ?: return@runSuspendCatching null
            val durationSec = (metadata.duration ?: 0L) / 1000L
            val currentSec = (metadata.viewOffset ?: 0L) / 1000L
            val fraction = if (durationSec > 0) currentSec.toFloat() / durationSec else 0f
            val finished = (metadata.viewCount ?: 0) > 0 || fraction >= 0.99f
            SyncSnapshot(
                percentage = if (finished) 1f else fraction.coerceIn(0f, 1f),
                positionMs = currentSec * 1000L,
                source = "plex",
                updatedAt = (metadata.lastViewedAt ?: 0L) * 1000L,
            )
        }
    }

    suspend fun resetBookProgress(book: Book): Result<Unit> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            val resp = api.unscrobble(ratingKey = book.id)
            if (!resp.isSuccessful) error("Plex unscrobble HTTP ${resp.code()}")
        }
    }

    suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            val (serverUrl, token) = scoped()
            val rootResp = api.getMetadata(book.id)
            if (!rootResp.isSuccessful) error("Plex metadata HTTP ${rootResp.code()}")
            val rootMeta = rootResp.body()?.mediaContainer?.metadata?.firstOrNull()
                ?: return@runSuspendCatching emptyList<AudioTrack>()
            val tracks = if (rootMeta.type == "album" || rootMeta.media.isEmpty()) {
                val childrenResp = api.getMetadataChildren(book.id)
                if (!childrenResp.isSuccessful) error("Plex children HTTP ${childrenResp.code()}")
                childrenResp.body()?.mediaContainer?.metadata.orEmpty()
            } else {

                listOf(rootMeta)
            }
            var cumulative = 0L
            tracks.sortedWith(plexTrackOrder).mapIndexedNotNull { idx, t ->
                val part = t.media.firstOrNull()?.part?.firstOrNull() ?: return@mapIndexedNotNull null
                val durationMs = t.duration ?: part.duration ?: 0L
                val track = AudioTrack(
                    index = idx,
                    fileName = part.file?.substringAfterLast('/') ?: t.title,
                    title = t.title,
                    durationMs = durationMs,
                    fileSizeBytes = 0L,
                    cumulativeStartMs = cumulative,
                    contentUrl = buildStreamUrl(serverUrl, part.key, token),
                )
                cumulative += durationMs
                track
            }
        }
    }

    suspend fun fetchChapters(book: Book): Result<List<Chapter>> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            val rootResp = api.getMetadata(book.id, includeChapters = 1)
            if (!rootResp.isSuccessful) error("Plex chapters HTTP ${rootResp.code()}")
            val rootMeta = rootResp.body()?.mediaContainer?.metadata?.firstOrNull()
                ?: return@runSuspendCatching emptyList()

            if (rootMeta.chapter.isNotEmpty()) {
                return@runSuspendCatching rootMeta.chapter.mapIndexed { idx, c -> c.toChapter(idx) }
            }

            if (rootMeta.type == "album") {
                val childrenResp = api.getMetadataChildren(book.id)
                if (!childrenResp.isSuccessful) error("Plex children HTTP ${childrenResp.code()}")
                val children = childrenResp.body()?.mediaContainer?.metadata.orEmpty()

                if (children.size == 1) {
                    val trackKey = children.first().ratingKey
                    val trackResp = api.getMetadata(trackKey, includeChapters = 1)
                    if (!trackResp.isSuccessful) error("Plex chapters HTTP ${trackResp.code()}")
                    val trackChapters = trackResp.body()?.mediaContainer?.metadata?.firstOrNull()?.chapter.orEmpty()
                    if (trackChapters.isNotEmpty()) {
                        return@runSuspendCatching trackChapters.mapIndexed { idx, c -> c.toChapter(idx) }
                    }
                }

                if (children.size > 1) {
                    val tracks = getAudioTracks(book).getOrThrow()
                    val synthesized = synthesizeChaptersFromTracks(tracks, book.duration)
                    if (synthesized.isNotEmpty()) return@runSuspendCatching synthesized
                }
            }

            emptyList()
        }
    }

    suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            val tracks = getAudioTracks(book).getOrThrow()
            if (tracks.isEmpty()) error("Plex returned no audio tracks")
            val chapters = fetchChapters(book).getOrDefault(emptyList())
            ProviderPlaybackSession(
                sessionId = "plex-${book.id}-${System.currentTimeMillis()}",
                audioTracks = tracks,
                chapters = chapters,
            )
        }
    }

    private fun PlexChapter.toChapter(idx: Int): Chapter = Chapter(
        index = idx,
        title = tag ?: title ?: "Chapter ${idx + 1}",
        startTime = startTimeOffset / 1000L,
        endTime = endTimeOffset / 1000L,
    )

    suspend fun getOnDeck(): Result<List<Book>> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            val (serverUrl, _) = scoped()
            val resp = api.getOnDeck(size = 50)
            if (!resp.isSuccessful) error("Plex on-deck HTTP ${resp.code()}")
            val items = resp.body()?.mediaContainer?.metadata.orEmpty()
            items
                .filter { it.type == "album" }
                .map { it.toBook(serverUrl, libraryId = it.parentRatingKey ?: "") }
        }
    }

    private suspend fun fetchAllBooks(
        sectionId: String,
        serverUrl: String,
        sort: String? = null,
        limit: Int = 500,
    ): List<Book> {

        val albums = paginate(sectionId, type = 9, sort = sort, limit = limit)
        if (albums.isNotEmpty()) return expandAlbums(albums, sectionId, serverUrl)

        val viaTracks = paginate(sectionId, type = 10, sort = sort, limit = limit)
        return viaTracks
            .groupBy { it.parentRatingKey ?: "track:${it.ratingKey}" }
            .values
            .map { it.toTrackFallbackBook(serverUrl, sectionId) }
    }

    private fun expandAlbums(
        albums: List<PlexMetadata>,
        sectionId: String,
        serverUrl: String,
    ): List<Book> = albums.map { it.toBook(serverUrl, sectionId) }

    private fun List<PlexMetadata>.toTrackFallbackBook(serverUrl: String, libraryId: String): Book {
        val tracks = sortedWith(plexTrackOrder)
        val primary = tracks.first()
        val albumId = primary.parentRatingKey ?: return primary.toBook(serverUrl, libraryId)
        val title = primary.parentTitle ?: primary.title
        val author = primary.grandparentTitle ?: primary.parentTitle
        val series = primary.copy(title = title).extractSeries(author)
        val coverPath = primary.parentThumb ?: primary.thumb ?: primary.grandparentThumb

        return Book(
            id = albumId,
            title = title,
            author = author,
            seriesName = series?.name,
            seriesNumber = series?.sequence,
            coverUrl = coverPath?.let { "$serverUrl${if (it.startsWith('/')) it else "/$it"}" },
            duration = tracks.sumOf { (it.duration ?: 0L) / 1000L },
            currentTime = 0L,
            readProgress = 0f,
            isFinished = false,
            description = primary.summary,
            source = BookSource.PLEX,
            mediaType = AppMediaType.AUDIOBOOK,
            libraryId = libraryId,
            addedOn = (primary.addedAt ?: 0L) * 1000L,
            lastReadTime = (primary.lastViewedAt ?: 0L) * 1000L,
            hasAudio = true,
        )
    }

    private suspend fun paginate(
        sectionId: String,
        type: Int,
        sort: String?,
        limit: Int,
    ): List<PlexMetadata> {
        val pageSize = 100
        val all = mutableListOf<PlexMetadata>()
        var start = 0
        while (true) {
            val remaining = limit - all.size
            if (remaining <= 0) break
            val take = remaining.coerceAtMost(pageSize)
            val resp = api.getSectionItems(
                sectionId = sectionId,
                type = type,
                sort = sort,
                start = start,
                size = take,
            )
            if (!resp.isSuccessful) error("Plex section items HTTP ${resp.code()}")
            val container = resp.body()?.mediaContainer ?: break
            val items = container.metadata
            if (items.isEmpty()) break
            all += items
            start += items.size
            if (items.size < take) break
            if (start >= container.totalSize && container.totalSize > 0) break
        }
        return all
    }

    private val plexTrackOrder = compareBy<PlexMetadata>(
        { it.parentIndex ?: 0 },
        { it.index ?: Int.MAX_VALUE },
        { it.ratingKey },
    )

    private fun PlexMetadata.toBook(serverUrl: String, libraryId: String): Book {
        val durationSec = (duration ?: 0L) / 1000L
        val currentTimeSec = (viewOffset ?: 0L) / 1000L
        val readProgress = if (durationSec > 0) currentTimeSec.toFloat() / durationSec else 0f
        val finished = (viewCount ?: 0) > 0 || readProgress >= 0.99f
        val coverPath = thumb ?: parentThumb ?: grandparentThumb
        val bookAuthor = grandparentTitle ?: parentTitle
        val series = extractSeries(bookAuthor)
        return Book(
            id = ratingKey,
            title = title,
            author = bookAuthor,
            seriesName = series?.name,
            seriesNumber = series?.sequence,
            coverUrl = coverPath?.let { "$serverUrl${if (it.startsWith('/')) it else "/$it"}" },
            duration = durationSec,
            currentTime = currentTimeSec,
            readProgress = if (finished) 1f else readProgress.coerceIn(0f, 1f),
            isFinished = finished,
            description = summary,
            source = BookSource.PLEX,
            mediaType = AppMediaType.AUDIOBOOK,
            libraryId = libraryId,
            addedOn = (addedAt ?: 0L) * 1000L,
            lastReadTime = (lastViewedAt ?: 0L) * 1000L,
            hasAudio = true,
        )
    }

    private data class PlexSeries(val name: String, val sequence: String?)

    private val seriesTitlePatterns = listOf(
        Regex("""^(.*?)(?:\s*[-\u2013\u2014:,]\s*|\s+)(?:book|bk|vol(?:ume)?|part|#)\s*([0-9]+(?:\.[0-9]+)?)\s*$""", RegexOption.IGNORE_CASE),
        Regex("""^(.*?)\s*\((?:book|vol(?:ume)?|part|#)\s*([0-9]+(?:\.[0-9]+)?)\)\s*$""", RegexOption.IGNORE_CASE),
    )

    private val sequencePatterns = listOf(
        Regex("""(?:book|bk|vol(?:ume)?|part|#)\s*([0-9]+(?:\.[0-9]+)?)""", RegexOption.IGNORE_CASE),
        Regex("""^(\d{1,3}(?:\.\d+)?)\s*[-\u2013\u2014:.]"""),
    )

    private fun PlexMetadata.extractSeries(author: String?): PlexSeries? {
        parseSeriesFromTitle(title)?.let { return it }
        val filePath = media.firstOrNull()?.part?.firstOrNull()?.file ?: return null
        return parseSeriesFromPath(filePath, author, title)
    }

    private fun parseSeriesFromTitle(title: String): PlexSeries? {
        val trimmed = title.trim()
        for (re in seriesTitlePatterns) {
            val m = re.find(trimmed) ?: continue
            val name = m.groupValues[1].trim()
            val seq = m.groupValues[2].trim()
            if (name.isNotEmpty() && seq.isNotEmpty()) return PlexSeries(name, seq)
        }
        return null
    }

    private fun parseSeriesFromPath(filePath: String, author: String?, title: String): PlexSeries? {
        val segments = filePath.replace('\\', '/').split('/').filter { it.isNotEmpty() }
        if (segments.size < 2) return null
        val bookFolder = segments[segments.size - 2]
        val seriesCandidate = segments.getOrNull(segments.size - 3).orEmpty()
        val authorLower = author?.lowercase().orEmpty()
        val titleLower = title.lowercase()

        fun usable(name: String): Boolean {
            val lower = name.lowercase()
            if (name.isEmpty()) return false
            if (authorLower.isNotEmpty() && lower == authorLower) return false
            if (lower == titleLower) return false
            if (lower == bookFolder.lowercase()) return false
            return true
        }

        val seriesName = when {
            usable(seriesCandidate) -> seriesCandidate
            usable(bookFolder) -> bookFolder
            else -> return null
        }
        return PlexSeries(seriesName, extractSequence(title) ?: extractSequence(bookFolder))
    }

    private fun extractSequence(text: String): String? {
        val trimmed = text.trim()
        for (re in sequencePatterns) {
            val seq = re.find(trimmed)?.groupValues?.getOrNull(1)?.trim()
            if (!seq.isNullOrEmpty()) return seq
        }
        return null
    }

    private fun PlexSection.toLibrary(): Library = Library(
        id = key,
        name = title,
        bookCount = 0,
    )

    private fun PlexSection.isAudiobookSection(): Boolean =
        isLikelyPlexAudiobookSection(type, title, agent, scanner)
}
