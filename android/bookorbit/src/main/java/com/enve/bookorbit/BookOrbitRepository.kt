package com.enve.bookorbit

import com.enve.bookorbit.api.BookOrbitApi
import com.enve.bookorbit.dto.BookOrbitAudiobookAssetDto
import com.enve.bookorbit.dto.BookOrbitAudiobookManifestDto
import com.enve.bookorbit.dto.BookOrbitAudiobookPlaybackStateRequest
import com.enve.bookorbit.dto.BookOrbitBookCardDto
import com.enve.bookorbit.dto.BookOrbitBookDetailDto
import com.enve.bookorbit.dto.BookOrbitBookmarkRequest
import com.enve.bookorbit.dto.BookOrbitBooksPageDto
import com.enve.bookorbit.dto.BookOrbitBooksPageRequest
import com.enve.bookorbit.dto.BookOrbitChapterDto
import com.enve.bookorbit.dto.BookOrbitCollectionBooksRequest
import com.enve.bookorbit.dto.BookOrbitCollectionDto
import com.enve.bookorbit.dto.BookOrbitCollectionOrderItem
import com.enve.bookorbit.dto.BookOrbitCollectionOrderRequest
import com.enve.bookorbit.dto.BookOrbitCollectionRequest
import com.enve.bookorbit.dto.BookOrbitCreateAnnotationRequest
import com.enve.bookorbit.dto.BookOrbitEbookProgressRequest
import com.enve.bookorbit.dto.BookOrbitFileDto
import com.enve.bookorbit.dto.BookOrbitPaginationRequest
import com.enve.bookorbit.dto.BookOrbitReadingSessionRequest
import com.enve.bookorbit.dto.BookOrbitReadingSessionDto
import com.enve.bookorbit.dto.BookOrbitRatingRequest
import com.enve.bookorbit.dto.BookOrbitStatusRequest
import com.enve.bookorbit.dto.BookOrbitUpdateAnnotationRequest
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.ReadStatus
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.provider.ProviderEbookResource
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.sync.AcceptedAnnotation
import com.enve.core.data.sync.AnnotationsPushResult
import com.enve.core.data.sync.RejectedAnnotation
import com.enve.core.data.util.runSuspendCatching
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import java.time.Instant
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.roundToLong
import retrofit2.Response

data class BookOrbitCollectionPage(
    val items: List<Book>,
    val total: Int,
    val page: Int,
    val size: Int,
)

data class BookOrbitReadingSessionRecord(
    val id: Int,
    val startedAtMs: Long,
    val endedAtMs: Long,
    val durationSeconds: Long,
    val progressDelta: Float?,
    val endProgress: Float?,
    val mediaType: AppMediaType,
    val source: String?,
)

@Singleton
class BookOrbitRepository @Inject constructor(
    private val api: BookOrbitApi,
    private val endpoints: BookOrbitEndpoints,
) {
    suspend fun isCurrentUserAdmin(): Result<Boolean> = runSuspendCatching {
        val response = api.me()
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit account lookup failed", response))
        response.body()?.isSuperuser == true
    }

    suspend fun getCollections(bookIds: List<Int> = emptyList()): Result<List<BookOrbitCollectionDto>> = runSuspendCatching {
        val response = api.collections(bookIds.takeIf { it.isNotEmpty() }?.distinct()?.joinToString(","))
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit collections failed", response))
        response.body().orEmpty().sortedWith(compareBy<BookOrbitCollectionDto> { it.displayOrder }.thenBy { it.name.lowercase() })
    }

    suspend fun getCollectionBooks(
        collectionId: Int,
        page: Int,
        size: Int,
        query: String? = null,
    ): Result<BookOrbitCollectionPage> = runSuspendCatching {
        val response = api.collectionBooks(collectionId, page.coerceAtLeast(0), size.coerceIn(1, 100), query?.takeIf { it.isNotBlank() })
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit collection books failed", response))
        val body = response.body() ?: BookOrbitBooksPageDto()
        BookOrbitCollectionPage(
            items = body.items.map { it.toBook(libraryId = null) },
            total = body.total,
            page = body.page,
            size = body.size,
        )
    }

    suspend fun createCollection(request: BookOrbitCollectionRequest): Result<BookOrbitCollectionDto> = adminMutation {
        api.createCollection(request)
    }

    suspend fun updateCollection(id: Int, request: BookOrbitCollectionRequest): Result<BookOrbitCollectionDto> = adminMutation {
        api.updateCollection(id, request)
    }

    suspend fun deleteCollection(id: Int): Result<Unit> = adminUnitMutation {
        api.deleteCollection(id)
    }

    suspend fun addCollectionBooks(id: Int, bookIds: List<Int>): Result<Unit> = adminCollectionUnitMutation {
        api.addCollectionBooks(id, BookOrbitCollectionBooksRequest(bookIds.distinct()))
    }

    suspend fun removeCollectionBooks(id: Int, bookIds: List<Int>): Result<Unit> = adminCollectionUnitMutation {
        api.removeCollectionBooks(id, BookOrbitCollectionBooksRequest(bookIds.distinct()))
    }

    suspend fun reorderCollections(ids: List<Int>): Result<Unit> = adminUnitMutation {
        api.reorderCollections(
            BookOrbitCollectionOrderRequest(ids.distinct().mapIndexed { index, id -> BookOrbitCollectionOrderItem(id, index) }),
        )
    }

    private suspend fun adminMutation(
        request: suspend () -> Response<BookOrbitCollectionDto>,
    ): Result<BookOrbitCollectionDto> = runSuspendCatching {
        requireAdmin()
        val response = request()
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit collection update failed", response))
        response.body() ?: error("BookOrbit returned an empty collection response")
    }

    private suspend fun adminUnitMutation(request: suspend () -> Response<Unit>): Result<Unit> = runSuspendCatching {
        requireAdmin()
        val response = request()
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit collection update failed", response))
    }

    private suspend fun adminCollectionUnitMutation(
        request: suspend () -> Response<BookOrbitCollectionDto>,
    ): Result<Unit> = runSuspendCatching {
        requireAdmin()
        val response = request()
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit collection update failed", response))
    }

    private suspend fun requireAdmin() {
        check(isCurrentUserAdmin().getOrThrow()) { "BookOrbit collection changes require an administrator account" }
    }

    suspend fun getLibraries(): Result<List<Library>> = runSuspendCatching {
        val response = api.libraries()
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit libraries failed", response))
        response.body().orEmpty().map {
            Library(
                id = it.id.toString(),
                name = it.name,
                source = BookSource.BOOKORBIT,
                connectionId = currentConnection()?.id,
            )
        }
    }

    suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
    ): Result<List<Book>> = runSuspendCatching {
        val libId = libraryId?.toIntOrNull()
            ?: getLibraries().getOrThrow().firstOrNull()?.id?.toIntOrNull()
            ?: return@runSuspendCatching emptyList()
        val requestedSize = size.coerceAtLeast(1)
        val requestedStart = page.coerceAtLeast(0).toLong() * requestedSize.toLong()
        val maxReachable = (SERVER_PAGE_CEILING + 1L) * SERVER_PAGE_SIZE
        if (requestedStart >= maxReachable) return@runSuspendCatching emptyList()

        val firstServerPage = (requestedStart / SERVER_PAGE_SIZE).toInt()
        val requestedEnd = requestedStart + requestedSize
        val lastServerPage = ((requestedEnd - 1L) / SERVER_PAGE_SIZE).toInt().coerceAtMost(SERVER_PAGE_CEILING)
        val cards = mutableListOf<BookOrbitBookCardDto>()

        for (serverPage in firstServerPage..lastServerPage) {
            val dto = fetchBooksPage(libId, serverPage, SERVER_PAGE_SIZE)
            cards += dto.items
            if (dto.items.size < SERVER_PAGE_SIZE || (serverPage + 1) * SERVER_PAGE_SIZE >= dto.total) break
        }

        val dropCount = (requestedStart - firstServerPage.toLong() * SERVER_PAGE_SIZE).toInt()
        cards.drop(dropCount)
            .take(requestedSize)
            .map { it.toBook(libraryId = libId.toString()) }
    }

    suspend fun getRecentlyAdded(limit: Int = 20): Result<List<Book>> = runSuspendCatching {
        val finalLimit = limit.coerceAtLeast(1)
        val libraries = getLibraries().getOrThrow()
        libraries.flatMap { library ->
            val libId = library.id.toIntOrNull() ?: return@flatMap emptyList()
            val requestedLimit = finalLimit
            val total = fetchBooksPage(libId, page = 0, size = 1).total
            if (total <= 0) return@flatMap emptyList()

            val reachableTotal = total.coerceAtMost((SERVER_PAGE_CEILING + 1) * SERVER_PAGE_SIZE)
            val firstIndex = (reachableTotal - requestedLimit).coerceAtLeast(0)
            val firstPage = firstIndex / SERVER_PAGE_SIZE
            val lastPage = (reachableTotal - 1) / SERVER_PAGE_SIZE
            val cards = mutableListOf<BookOrbitBookCardDto>()

            for (serverPage in firstPage..lastPage) {
                val dto = fetchBooksPage(libId, serverPage, SERVER_PAGE_SIZE)
                cards += dto.items
                if (dto.items.size < SERVER_PAGE_SIZE || (serverPage + 1) * SERVER_PAGE_SIZE >= dto.total) break
            }

            val dropCount = firstIndex - firstPage * SERVER_PAGE_SIZE
            cards.drop(dropCount)
                .take(requestedLimit)
                .asReversed()
                .map { it.toBook(library.id) }
        }.sortedByDescending { it.addedOn }.take(finalLimit)
    }

    suspend fun getContinueListening(): Result<List<Book>> =
        getCurrentlyReadingBooks(ContinueKind.LISTENING)

    suspend fun getContinueReading(): Result<List<Book>> =
        getCurrentlyReadingBooks(ContinueKind.READING)

    private suspend fun getCurrentlyReadingBooks(
        kind: ContinueKind,
    ): Result<List<Book>> = runSuspendCatching {
        val response = api.currentlyReading()
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit currently-reading failed", response))
        coroutineScope {
            response.body()?.books.orEmpty()
                .mapIndexed { index, item ->
                    async {
                        val book = getBook(item.bookId.toString(), null).getOrNull() ?: return@async null
                        val listening = item.fileFormat?.let(::isAudio) ?: (book.mediaType == AppMediaType.AUDIOBOOK)
                        if ((kind == ContinueKind.LISTENING) != listening) return@async null
                        val exact = if (listening) {
                            runSuspendCatching { fetchDirectAudiobookProgress(book) }.getOrNull()
                        } else {
                            runSuspendCatching {
                                item.fileId?.let { fetchDirectEbookProgress(it) }
                                    ?: fetchEbookProgress(book).getOrNull()
                            }.getOrNull()
                        }
                        val widgetProgress = ((item.progress ?: 0.0) / 100.0).toFloat().coerceIn(0f, 1f)
                        val progress = exact?.percentage ?: widgetProgress
                        if (progress !in 0.001f..0.999f) return@async null
                        val updatedAt = exact?.updatedAt ?: 0L
                        val resolved = if (listening) {
                            val current = exact?.positionMs?.div(1000L)
                                ?: if (book.duration > 0L) (book.duration * progress).roundToLong() else 1L
                            book.copy(currentTime = current, readProgress = progress, lastReadTime = updatedAt)
                        } else {
                            book.copy(
                                mediaType = AppMediaType.EBOOK,
                                duration = 0L,
                                currentTime = 0L,
                                epubProgress = progress,
                                readProgress = progress,
                                epubLocator = exact?.locatorJson ?: book.epubLocator,
                                lastReadTime = updatedAt,
                            )
                        }
                        IndexedValue(index, resolved)
                    }
                }
                .awaitAll()
                .filterNotNull()
                .sortedWith(compareByDescending<IndexedValue<Book>> { it.value.lastReadTime }.thenBy { it.index })
                .map(IndexedValue<Book>::value)
        }
    }

    suspend fun getBook(bookId: String, fallbackLibraryId: String?): Result<Book> = runSuspendCatching {
        val id = bookId.toIntOrNull() ?: error("Invalid BookOrbit book id")
        val response = api.book(id)
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit book detail failed", response))
        response.body()?.toBook(fallbackLibraryId) ?: error("BookOrbit returned an empty book detail")
    }

    suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = runSuspendCatching {
        audiobookTracks(book).first
    }

    suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runSuspendCatching {
        val detailed = getBook(book.id, book.libraryId).getOrElse { book }
        val (tracks, manifest) = audiobookTracks(detailed)
        if (tracks.isEmpty()) error("BookOrbit returned no playable audio tracks")
        ProviderPlaybackSession(
            sessionId = "bookorbit:${book.id}",
            audioTracks = tracks,
            chapters = makeChapters(manifest.chapters, manifest.totalDurationMs / 1000L)
                .ifEmpty { synthesizeChapters(tracks, manifest.totalDurationMs / 1000L) },
        )
    }

    suspend fun syncAudiobookProgress(
        book: Book,
        currentTimeSec: Long,
        progressFraction: Float,
    ): Result<Unit> = runSuspendCatching {
        val bookId = book.id.toIntOrNull() ?: return@runSuspendCatching
        val manifest = fetchAudiobookManifest(bookId)
        val assets = manifest.assets.sortedBy { it.sequence }
        val (asset, localPositionMs) = assetAndOffset(assets, currentTimeSec * 1000L)
        val selected = asset ?: return@runSuspendCatching
        val current = api.audiobookPlaybackState(bookId).let { response ->
            if (response.code() == 404 || response.code() == 204) null
            else if (response.isSuccessful) response.body()
            else error(bookOrbitHttpMessage("BookOrbit audio progress pull failed", response))
        }
        val response = api.updateAudiobookPlaybackState(
            bookId = bookId,
            request = BookOrbitAudiobookPlaybackStateRequest(
                assetId = selected.assetId,
                positionMs = localPositionMs,
                capturedAt = Instant.now().toString(),
                operationId = UUID.randomUUID().toString(),
                baseRevision = current?.revision ?: 0,
                manifestRevision = manifest.revision,
            ),
        )
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit audio progress sync failed", response))
    }

    suspend fun fetchAudiobookProgress(book: Book): Result<SyncSnapshot?> = runSuspendCatching {
        fetchDirectAudiobookProgress(book) ?: fetchCurrentlyReadingAudiobookProgress(book)
    }

    private suspend fun fetchDirectAudiobookProgress(book: Book): SyncSnapshot? {
        val bookId = book.id.toIntOrNull() ?: return null
        val response = api.audiobookPlaybackState(bookId)
        if (response.code() == 404 || response.code() == 204) return null
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit audio progress pull failed", response))
        val dto = response.body() ?: return null
        val manifest = fetchAudiobookManifest(bookId)
        val assets = manifest.assets.sortedBy { it.sequence }
        val trackIndex = assets.indexOfFirst { it.assetId == dto.assetId }
        if (trackIndex < 0) return null
        val globalMs = assets.take(trackIndex).sumOf { it.durationMs ?: 0L } + dto.positionMs.coerceAtLeast(0L)
        val percentage = ((dto.percentage ?: 0.0) / 100.0).toFloat().coerceIn(0f, 1f)
        val durationMs = manifest.totalDurationMs.takeIf { it > 0L } ?: assets.sumOf { it.durationMs ?: 0L }
        return SyncSnapshot(
            percentage = if (percentage > 0.001f || durationMs <= 0L) {
                percentage
            } else {
                (globalMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
            },
            positionMs = globalMs,
            locatorJson = null,
            updatedAt = null,
            source = BookSource.BOOKORBIT.displayName,
        )
    }

    private suspend fun fetchAudiobookManifest(bookId: Int): BookOrbitAudiobookManifestDto {
        val response = api.audiobookManifest(bookId)
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit audiobook manifest failed", response))
        return response.body() ?: error("BookOrbit returned an empty audiobook manifest")
    }

    private suspend fun audiobookTracks(book: Book): Pair<List<AudioTrack>, BookOrbitAudiobookManifestDto> {
        val bookId = book.id.toIntOrNull() ?: error("Invalid BookOrbit book id")
        val manifest = fetchAudiobookManifest(bookId)
        var offsetMs = 0L
        val sourceTracks = book.audioTracks
        val tracks = manifest.assets.sortedBy { it.sequence }.mapIndexed { index, asset ->
            val durationMs = (asset.durationMs ?: 0L).coerceAtLeast(0L)
            AudioTrack(
                index = index,
                fileName = sourceTracks.getOrNull(index)?.fileName ?: "Track ${index + 1}",
                title = sourceTracks.getOrNull(index)?.title,
                durationMs = durationMs,
                fileSizeBytes = asset.sizeBytes ?: 0L,
                cumulativeStartMs = offsetMs,
                fileId = asset.assetId,
                contentUrl = audiobookAssetUrl(book.id, asset.assetId),
            ).also { offsetMs += durationMs }
        }
        return tracks to manifest
    }

    private fun assetAndOffset(
        assets: List<BookOrbitAudiobookAssetDto>,
        globalPositionMs: Long,
    ): Pair<BookOrbitAudiobookAssetDto?, Long> {
        var elapsed = 0L
        assets.forEachIndexed { index, asset ->
            val duration = (asset.durationMs ?: 0L).coerceAtLeast(0L)
            if (globalPositionMs < elapsed + duration || index == assets.lastIndex) {
                return asset to (globalPositionMs - elapsed).coerceIn(0L, duration.takeIf { it > 0L } ?: Long.MAX_VALUE)
            }
            elapsed += duration
        }
        return null to globalPositionMs.coerceAtLeast(0L)
    }

    private suspend fun fetchCurrentlyReadingAudiobookProgress(book: Book): SyncSnapshot? {
        val bookId = book.id.toIntOrNull() ?: return null
        val response = api.currentlyReading()
        if (!response.isSuccessful) return null
        val entry = response.body()?.books.orEmpty().firstOrNull { it.bookId == bookId } ?: return null
        val isListening = entry.fileFormat?.let(::isAudio) ?: (book.mediaType == AppMediaType.AUDIOBOOK)
        if (!isListening) return null
        return progressSnapshotFromPercentage(
            book = book,
            percentagePercent = entry.progress,
            updatedAt = null,
        )
    }

    private suspend fun progressSnapshotFromPercentage(
        book: Book,
        percentagePercent: Double?,
        updatedAt: Long?,
    ): SyncSnapshot? {
        val percentage = ((percentagePercent ?: 0.0) / 100.0).toFloat().coerceIn(0f, 1f)
        if (percentage <= 0.001f) return null
        val durationSec = durationForProgress(book)
        return SyncSnapshot(
            percentage = percentage,
            positionMs = if (durationSec > 0L) {
                (durationSec.toDouble() * percentage.toDouble() * 1000.0).roundToLong()
            } else {
                null
            },
            locatorJson = null,
            updatedAt = updatedAt,
            source = BookSource.BOOKORBIT.displayName,
        )
    }

    suspend fun syncEbookProgress(
        bookId: String,
        percentage: Float,
        locator: String?,
    ): Result<Unit> = runSuspendCatching {
        val fileId = primaryEbookFileId(bookId) ?: error("BookOrbit ebook file unavailable")
        val response = api.updateEbookProgress(
            fileId = fileId,
            request = BookOrbitEbookProgressRequest(
                percentage = (percentage * 100.0).coerceIn(0.0, 100.0),
                cfi = bookOrbitFoliateCfi(locator),
            ),
        )
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit ebook progress sync failed", response))
    }

    suspend fun fetchEbookProgress(book: Book): Result<SyncSnapshot?> = runSuspendCatching {
        val fileId = primaryEbookFileId(book.id) ?: return@runSuspendCatching null
        fetchDirectEbookProgress(fileId)
    }

    private suspend fun fetchDirectEbookProgress(fileId: Int): SyncSnapshot? {
        val response = api.ebookProgress(fileId)
        if (response.code() == 404 || response.code() == 204) return null
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit ebook progress pull failed", response))
        val dto = response.body() ?: return null
        return bookOrbitEbookSnapshot(dto.cfi, dto.percentage, bookOrbitDateMillis(dto.updatedAt))
    }

    suspend fun updateBookStatus(bookId: String, status: String): Result<Unit> = runSuspendCatching {
        val id = bookId.toIntOrNull() ?: error("Invalid BookOrbit book id")
        val mapped = when (status.uppercase()) {
            "READ", "COMPLETED" -> "read"
            "IN_PROGRESS", "READING" -> "reading"
            "ON_HOLD", "PAUSED" -> "on_hold"
            "REREADING" -> "rereading"
            "WANT_TO_READ" -> "want_to_read"
            "SKIMMED" -> "skimmed"
            "ABANDONED" -> "abandoned"
            else -> "unread"
        }
        val response = api.updateStatus(id, BookOrbitStatusRequest(mapped))
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit read status update failed", response))
    }

    suspend fun updatePersonalRating(bookId: String, rating: Int): Result<Unit> = runSuspendCatching {
        val id = bookId.toIntOrNull() ?: error("Invalid BookOrbit book id")
        val response = api.updateRating(id, BookOrbitRatingRequest(rating.coerceIn(1, 5)))
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit rating update failed", response))
    }

    suspend fun pushAnnotations(
        book: Book,
        annotations: List<ReaderAnnotation>,
    ): Result<AnnotationsPushResult> = runSuspendCatching { pushArtifacts(book, annotations) }

    private suspend fun pushArtifacts(
        book: Book,
        annotations: List<ReaderAnnotation>,
    ): AnnotationsPushResult {
        val bookId = book.id.toIntOrNull() ?: error("Invalid BookOrbit book id")
        val accepted = mutableListOf<AcceptedAnnotation>()
        val rejected = mutableListOf<RejectedAnnotation>()

        suspend fun attempt(annotation: ReaderAnnotation, block: suspend () -> AcceptedAnnotation) {
            try {
                accepted += block()
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                rejected += RejectedAnnotation(annotation.id, t.message ?: "BookOrbit reader-artifact sync failed")
            }
        }

        for (annotation in annotations) {
            when (annotation.bookOrbitArtifactPush()) {
                BookOrbitArtifactPush.FOREIGN ->
                    rejected += RejectedAnnotation(annotation.id, "Reader artifact belongs to another provider")
                BookOrbitArtifactPush.UNSUPPORTED ->
                    rejected += RejectedAnnotation(annotation.id, "BookOrbit cannot store this reader artifact")
                BookOrbitArtifactPush.DELETE -> attempt(annotation) {
                    annotation.serverId?.let { deleteRemoteArtifact(bookId, it) }
                    AcceptedAnnotation(annotation.id, annotation.serverId)
                }
                BookOrbitArtifactPush.BOOKMARK -> attempt(annotation) { pushBookmark(bookId, annotation) }
                BookOrbitArtifactPush.CREATE_HIGHLIGHT -> attempt(annotation) { createHighlight(bookId, annotation) }
                BookOrbitArtifactPush.UPDATE_HIGHLIGHT -> attempt(annotation) { updateHighlight(bookId, annotation) }
            }
        }
        return AnnotationsPushResult(accepted = accepted, rejected = rejected)
    }

    private suspend fun pushBookmark(bookId: Int, annotation: ReaderAnnotation): AcceptedAnnotation {
        annotation.serverId?.let { deleteRemoteArtifact(bookId, it) }
        val response = api.createBookmark(
            bookId,
            BookOrbitBookmarkRequest(
                cfi = annotation.bookOrbitCfi()
                    ?.takeIf { AnnotationMedia.parse(annotation.media) == AnnotationMedia.EPUB },
                title = annotation.bookOrbitBookmarkTitle(),
                positionSeconds = annotation.audioPositionMs?.div(1_000.0),
            ),
        )
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit bookmark sync failed", response))
        val remote = response.body() ?: error("BookOrbit returned an empty bookmark response")
        return AcceptedAnnotation(annotation.id, "bookmark:${remote.id}")
    }

    private suspend fun createHighlight(bookId: Int, annotation: ReaderAnnotation): AcceptedAnnotation {
        val response = api.createAnnotation(
            bookId,
            BookOrbitCreateAnnotationRequest(
                cfi = annotation.bookOrbitCfi()!!,
                text = annotation.selectedText,
                color = annotation.colorHex,
                style = annotation.bookOrbitStyle(),
                note = annotation.note.takeIf { it.isNotBlank() },
                chapterTitle = annotation.chapterId,
            ),
        )
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit annotation sync failed", response))
        val remote = response.body() ?: error("BookOrbit returned an empty annotation response")
        return AcceptedAnnotation(annotation.id, remote.id.toString())
    }

    private suspend fun updateHighlight(bookId: Int, annotation: ReaderAnnotation): AcceptedAnnotation {
        val response = api.updateAnnotation(
            bookId,
            annotation.serverId!!.toInt(),
            BookOrbitUpdateAnnotationRequest(
                note = annotation.note.takeIf { it.isNotBlank() },
                color = annotation.colorHex,
                style = annotation.bookOrbitStyle(),
            ),
        )
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit annotation sync failed", response))
        val remote = response.body() ?: error("BookOrbit returned an empty annotation response")
        return AcceptedAnnotation(annotation.id, remote.id.toString())
    }

    suspend fun fetchAnnotations(book: Book): Result<List<ReaderAnnotation>> = runSuspendCatching {
        val bookId = book.id.toIntOrNull() ?: error("Invalid BookOrbit book id")
        coroutineScope {
            val annotations = async { api.annotations(bookId) }
            val bookmarks = async { api.bookmarks(bookId) }
            val annotationRows = bookOrbitOptionalRows("BookOrbit annotations failed", annotations.await())
            val bookmarkRows = bookOrbitOptionalRows("BookOrbit bookmarks failed", bookmarks.await())
            annotationRows.mapNotNull { it.toReaderAnnotationOrNull(book.id) } +
                bookmarkRows.mapNotNull { it.toReaderAnnotationOrNull(book.id) }
        }
    }

    suspend fun deleteRemoteAnnotation(book: Book, serverId: String): Result<Unit> = runSuspendCatching {
        val bookId = book.id.toIntOrNull() ?: error("Invalid BookOrbit book id")
        deleteRemoteArtifact(bookId, serverId)
    }

    suspend fun saveReadingSession(
        book: Book,
        sessionId: String,
        startedAt: Instant,
        endedAt: Instant,
        durationSeconds: Int,
        progressDelta: Double?,
        endProgress: Double?,
        positionSec: Long? = null,
    ): Result<Unit> = runSuspendCatching {
        if (durationSeconds < 10) return@runSuspendCatching
        val detailed = getBook(book.id, book.libraryId).getOrElse { book }
        val fileId = if (book.mediaType == AppMediaType.AUDIOBOOK && positionSec != null) {
            currentFileAndOffset(detailed, positionSec).first
        } else {
            detailed.audioTracks.firstOrNull()?.fileId?.toIntOrNull()
                ?: primaryEbookFileId(book.id)
        } ?: error("BookOrbit reading-session file unavailable")
        val response = api.saveReadingSession(
            fileId,
            BookOrbitReadingSessionRequest(
                sessionId = "enve-${sessionId}".take(64),
                startedAt = startedAt.toString(),
                endedAt = endedAt.toString(),
                durationSeconds = durationSeconds,
                progressDelta = progressDelta?.times(100.0)?.coerceIn(-100.0, 100.0),
                endProgress = endProgress?.times(100.0)?.coerceIn(0.0, 100.0),
            ),
        )
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit reading-session sync failed", response))
    }

    suspend fun fetchReadingSessions(book: Book): Result<List<BookOrbitReadingSessionRecord>> = runSuspendCatching {
        val bookId = book.id.toIntOrNull() ?: error("Invalid BookOrbit book id")
        val records = mutableListOf<BookOrbitReadingSessionRecord>()
        var page = 1
        while (true) {
            val response = api.readingSessions(bookId, page = page, pageSize = 100)
            if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit reading sessions failed", response))
            val body = response.body() ?: break
            records += body.items.mapNotNull { it.toRecord(book.mediaType) }
            if (records.size >= body.total || body.items.isEmpty()) break
            page += 1
        }
        records
    }

    suspend fun validateConnection(): Result<Boolean> = runSuspendCatching {
        val response = api.me()
        response.isSuccessful
    }

    suspend fun getEbookDownloadUrl(bookId: String): String? {
        val fileId = primaryEbookFileId(bookId) ?: return null
        return "${apiBaseUrl()}/books/files/$fileId/download"
    }

    suspend fun getEbookResource(bookId: String): ProviderEbookResource? {
        val file = primaryEbookFile(bookId) ?: return null
        return ProviderEbookResource(
            url = "${apiBaseUrl()}/books/files/${file.id}/download",
            providerFileId = file.id.toString(),
            format = file.format ?: "EPUB",
        )
    }

    private fun audiobookAssetUrl(bookId: String, assetId: String): String =
        "${apiBaseUrl()}/audiobooks/$bookId/assets/$assetId/content"

    fun invalidateCaches() = Unit

    private suspend fun fetchBooksPage(
        libraryId: Int,
        page: Int,
        size: Int,
    ): BookOrbitBooksPageDto {
        val response = api.books(
            libraryId = libraryId,
            request = BookOrbitBooksPageRequest(
                pagination = BookOrbitPaginationRequest(page = page, size = size),
            ),
        )
        if (!response.isSuccessful) error(bookOrbitHttpMessage("BookOrbit books failed", response))
        return response.body() ?: BookOrbitBooksPageDto()
    }

    private fun BookOrbitBookCardDto.toBook(libraryId: String?): Book {
        val audioFiles = files.filter { isAudio(it.format) }
        val ebookFiles = files.filterNot { isAudio(it.format) }
        val isAudiobook = audioFiles.isNotEmpty()
        val primaryFile = if (isAudiobook) {
            audioFiles.firstOrNull { it.role.equals("content", ignoreCase = true) } ?: audioFiles.firstOrNull()
        } else {
            ebookFiles.firstOrNull { it.role.equals("primary", ignoreCase = true) } ?: ebookFiles.firstOrNull()
        }
        val tracks = if (isAudiobook) buildTracks(audioFiles, includeDurations = false) else emptyList()
        val status = readStatus?.status.toReadStatus()
        return Book(
            id = id.toString(),
            title = title ?: "Untitled",
            subtitle = subtitle,
            author = authors.joinToString(", ").ifBlank { null },
            narrator = narrators.joinToString(", ").ifBlank { null },
            coverUrl = if (hasCover == true) coverUrl(id) else null,
            duration = 0L,
            source = BookSource.BOOKORBIT,
            mediaType = if (isAudiobook) AppMediaType.AUDIOBOOK else AppMediaType.EBOOK,
            readStatus = status,
            isFinished = status == ReadStatus.COMPLETED,
            serverReadStatus = readStatus?.status?.uppercase(),
            seriesName = seriesName,
            seriesNumber = seriesIndex,
            publisher = publisher,
            publishedDate = publishedYear?.toString(),
            isbn13 = isbn13,
            language = language,
            pageCount = pageCount,
            personalRating = rating,
            categories = (genres + tags).distinct(),
            primaryFileType = primaryFile?.format,
            libraryId = libraryId,
            connectionId = currentConnection()?.id,
            addedOn = bookOrbitDateMillis(addedAt) ?: 0L,
            audioTracks = tracks,
            hasAudio = audioFiles.isNotEmpty(),
            hasEbook = ebookFiles.isNotEmpty(),
        )
    }

    private fun BookOrbitBookDetailDto.toBook(fallbackLibraryId: String?): Book {
        val audioFiles = files.filter { isAudio(it.format) }
        val ebookFiles = files.filterNot { isAudio(it.format) }
        val isAudiobook = audioFiles.isNotEmpty()
        val primaryFile = if (isAudiobook) {
            audioFiles.firstOrNull { it.role.equals("content", ignoreCase = true) } ?: audioFiles.firstOrNull()
        } else {
            ebookFiles.firstOrNull { it.role.equals("primary", ignoreCase = true) } ?: ebookFiles.firstOrNull()
        }
        val totalDuration = (audioMetadata?.durationSeconds ?: audioFiles.sumOf { it.durationSeconds ?: 0.0 })
            .roundToLong()
            .coerceAtLeast(0L)
        val tracks = if (isAudiobook) buildTracks(audioFiles, includeDurations = true) else emptyList()
        val status = readStatus?.status.toReadStatus()
        return Book(
            id = id.toString(),
            title = title ?: "Untitled",
            subtitle = subtitle,
            author = authors.joinToString(", ") { it.name }.ifBlank { null },
            narrator = audioMetadata?.narrators?.joinToString(", ") { it.name }?.ifBlank { null },
            description = description,
            coverUrl = if (hasCover == true || coverSource != null) coverUrl(id) else null,
            duration = if (isAudiobook) totalDuration else 0L,
            source = BookSource.BOOKORBIT,
            mediaType = if (isAudiobook) AppMediaType.AUDIOBOOK else AppMediaType.EBOOK,
            readStatus = status,
            isFinished = status == ReadStatus.COMPLETED,
            serverReadStatus = readStatus?.status?.uppercase(),
            seriesName = seriesName,
            seriesNumber = seriesIndex,
            publisher = publisher,
            publishedDate = publishedYear?.toString(),
            isbn13 = isbn13,
            language = language,
            pageCount = pageCount,
            personalRating = rating,
            categories = (genres + tags).distinct(),
            primaryFileType = primaryFile?.format,
            libraryId = libraryId?.toString() ?: fallbackLibraryId,
            libraryName = libraryName,
            connectionId = currentConnection()?.id,
            addedOn = bookOrbitDateMillis(addedAt) ?: 0L,
            chapters = makeChapters(audioMetadata?.chapters.orEmpty(), totalDuration),
            audioTracks = tracks,
            hasAudio = audioFiles.isNotEmpty(),
            hasEbook = ebookFiles.isNotEmpty(),
        )
    }

    private fun buildTracks(files: List<BookOrbitFileDto>, includeDurations: Boolean): List<AudioTrack> {
        var offsetMs = 0L
        return files.mapIndexed { index, file ->
            val durationMs = if (includeDurations) ((file.durationSeconds ?: 0.0) * 1000.0).roundToLong().coerceAtLeast(0L) else 0L
            AudioTrack(
                index = index,
                fileName = file.filename ?: "Track ${index + 1}",
                title = file.filename,
                durationMs = durationMs,
                cumulativeStartMs = offsetMs,
                fileId = file.id.toString(),
                contentUrl = null,
            ).also {
                offsetMs += durationMs
            }
        }
    }

    private fun List<AudioTrack>.hasSeekableOffsets(): Boolean {
        if (isEmpty()) return false
        if (size == 1) return true
        return any { it.durationMs > 0L } && drop(1).any { it.cumulativeStartMs > 0L }
    }

    private suspend fun durationForProgress(book: Book): Long {
        if (book.duration > 0L && book.audioTracks.hasSeekableOffsets()) return book.duration
        val detailed = getBook(book.id, book.libraryId).getOrElse { book }
        return when {
            detailed.duration > 0L -> detailed.duration
            detailed.audioTracks.sumOf { it.durationMs } > 0L -> detailed.audioTracks.sumOf { it.durationMs } / 1000L
            book.duration > 0L -> book.duration
            else -> 0L
        }
    }

    private fun durationForProgress(book: Book, tracks: List<AudioTrack>): Long = when {
        book.duration > 0L && book.audioTracks.hasSeekableOffsets() -> book.duration
        tracks.sumOf { it.durationMs } > 0L -> tracks.sumOf { it.durationMs } / 1000L
        book.duration > 0L -> book.duration
        else -> 0L
    }

    private fun makeChapters(chapters: List<BookOrbitChapterDto>, totalDurationSec: Long): List<Chapter> {
        if (chapters.isEmpty()) return emptyList()
        val sorted = chapters.sortedBy { it.startMs }
        return sorted.mapIndexed { index, chapter ->
            val startSec = (chapter.startMs / 1000.0).roundToLong().coerceAtLeast(0L)
            val endSec = if (index < sorted.lastIndex) {
                (sorted[index + 1].startMs / 1000.0).roundToLong()
            } else {
                totalDurationSec.coerceAtLeast(startSec)
            }
            Chapter(
                index = index,
                title = chapter.title,
                startTime = startSec,
                endTime = endSec.coerceAtLeast(startSec),
            )
        }
    }

    private fun synthesizeChapters(tracks: List<AudioTrack>, durationSec: Long): List<Chapter> {
        if (tracks.size <= 1) return emptyList()
        return tracks.map { track ->
            val startSec = track.cumulativeStartMs / 1000L
            val endSec = when {
                track.durationMs > 0L -> (track.cumulativeStartMs + track.durationMs) / 1000L
                track.index == tracks.lastIndex && durationSec > 0L -> durationSec
                else -> startSec
            }
            Chapter(
                index = track.index,
                title = track.title ?: track.fileName,
                startTime = startSec,
                endTime = endSec.coerceAtLeast(startSec),
            )
        }
    }

    private suspend fun currentFileAndOffset(book: Book, globalPositionSec: Long): Pair<Int?, Long> {
        val tracks = book.audioTracks.takeIf { it.isNotEmpty() }
            ?: getAudioTracks(book).getOrNull()
        val track = tracks?.lastOrNull { it.cumulativeStartMs / 1000L <= globalPositionSec } ?: tracks?.firstOrNull()
        val trackFileId = track?.fileId?.toIntOrNull()
        if (trackFileId != null) {
            val offsetSec = globalPositionSec - (track.cumulativeStartMs / 1000L)
            return trackFileId to offsetSec
        }
        return null to globalPositionSec
    }

    private suspend fun primaryEbookFileId(bookId: String): Int? {
        return primaryEbookFile(bookId)?.id
    }

    private suspend fun primaryEbookFile(bookId: String): BookOrbitFileDto? {
        val id = bookId.toIntOrNull() ?: return null
        val response = api.book(id)
        if (!response.isSuccessful) return null
        val detail = response.body() ?: return null
        return detail.files
            .filterNot { isAudio(it.format) }
            .firstOrNull { it.role.equals("primary", ignoreCase = true) }
            ?: detail.files.firstOrNull { !isAudio(it.format) }
    }

    private fun coverUrl(bookId: Int): String = endpoints.coverUrl(bookId)

    private suspend fun deleteRemoteArtifact(bookId: Int, serverId: String) {
        val bookmarkId = serverId.removePrefix("bookmark:").toIntOrNull()
        val response = if (serverId.startsWith("bookmark:") && bookmarkId != null) {
            api.deleteBookmark(bookId, bookmarkId)
        } else {
            val annotationId = serverId.toIntOrNull() ?: return
            api.deleteAnnotation(bookId, annotationId)
        }
        if (!response.isSuccessful && response.code() != 404) {
            error(bookOrbitHttpMessage("BookOrbit reader-artifact deletion failed", response))
        }
    }

    private fun BookOrbitReadingSessionDto.toRecord(fallback: AppMediaType): BookOrbitReadingSessionRecord? {
        val started = bookOrbitDateMillis(startedAt) ?: return null
        val ended = bookOrbitDateMillis(endedAt) ?: return null
        return BookOrbitReadingSessionRecord(
            id = id,
            startedAtMs = started,
            endedAtMs = ended,
            durationSeconds = durationSeconds.toLong(),
            progressDelta = progressDelta?.div(100.0)?.toFloat()?.coerceIn(-1f, 1f),
            endProgress = endProgress?.div(100.0)?.toFloat()?.coerceIn(0f, 1f),
            mediaType = when {
                format == null -> fallback
                isAudio(format) -> AppMediaType.AUDIOBOOK
                else -> AppMediaType.EBOOK
            },
            source = source,
        )
    }

    private fun apiBaseUrl(): String = endpoints.apiBaseUrl()

    private fun currentConnection(): ProviderConnection? = endpoints.currentConnection()

    private fun String?.toReadStatus(): ReadStatus = when (this?.lowercase()) {
        "read" -> ReadStatus.COMPLETED
        "reading", "rereading" -> ReadStatus.IN_PROGRESS
        "on_hold" -> ReadStatus.ON_HOLD
        else -> ReadStatus.UNREAD
    }

    private fun isAudio(format: String?): Boolean =
        format?.lowercase() in setOf("m4b", "mp3", "m4a", "opus", "ogg", "flac", "wav", "aac", "aax")

    private enum class ContinueKind { LISTENING, READING }

    private companion object {
        const val SERVER_PAGE_SIZE = 200
        const val SERVER_PAGE_CEILING = 250
    }
}
