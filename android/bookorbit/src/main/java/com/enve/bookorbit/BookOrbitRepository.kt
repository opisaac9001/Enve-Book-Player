package com.enve.bookorbit

import com.enve.bookorbit.api.BookOrbitApi
import com.enve.bookorbit.dto.BookOrbitAudioProgressRequest
import com.enve.bookorbit.dto.BookOrbitAnnotationDto
import com.enve.bookorbit.dto.BookOrbitBookCardDto
import com.enve.bookorbit.dto.BookOrbitBookDetailDto
import com.enve.bookorbit.dto.BookOrbitBookmarkDto
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
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AnnotationStyle
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
import com.enve.core.reader.EpubBridgeCheckpointCodec
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
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
        if (!response.isSuccessful) error(httpMessage("BookOrbit account lookup failed", response))
        response.body()?.isSuperuser == true
    }

    suspend fun getCollections(bookIds: List<Int> = emptyList()): Result<List<BookOrbitCollectionDto>> = runSuspendCatching {
        val response = api.collections(bookIds.takeIf { it.isNotEmpty() }?.distinct()?.joinToString(","))
        if (!response.isSuccessful) error(httpMessage("BookOrbit collections failed", response))
        response.body().orEmpty().sortedWith(compareBy<BookOrbitCollectionDto> { it.displayOrder }.thenBy { it.name.lowercase() })
    }

    suspend fun getCollectionBooks(
        collectionId: Int,
        page: Int,
        size: Int,
        query: String? = null,
    ): Result<BookOrbitCollectionPage> = runSuspendCatching {
        val response = api.collectionBooks(collectionId, page.coerceAtLeast(0), size.coerceIn(1, 100), query?.takeIf { it.isNotBlank() })
        if (!response.isSuccessful) error(httpMessage("BookOrbit collection books failed", response))
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
        if (!response.isSuccessful) error(httpMessage("BookOrbit collection update failed", response))
        response.body() ?: error("BookOrbit returned an empty collection response")
    }

    private suspend fun adminUnitMutation(request: suspend () -> Response<Unit>): Result<Unit> = runSuspendCatching {
        requireAdmin()
        val response = request()
        if (!response.isSuccessful) error(httpMessage("BookOrbit collection update failed", response))
    }

    private suspend fun adminCollectionUnitMutation(
        request: suspend () -> Response<BookOrbitCollectionDto>,
    ): Result<Unit> = runSuspendCatching {
        requireAdmin()
        val response = request()
        if (!response.isSuccessful) error(httpMessage("BookOrbit collection update failed", response))
    }

    private suspend fun requireAdmin() {
        check(isCurrentUserAdmin().getOrThrow()) { "BookOrbit collection changes require an administrator account" }
    }

    suspend fun getLibraries(): Result<List<Library>> = runSuspendCatching {
        val response = api.libraries()
        if (!response.isSuccessful) error(httpMessage("BookOrbit libraries failed", response))
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
        if (!response.isSuccessful) error(httpMessage("BookOrbit currently-reading failed", response))
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
        if (!response.isSuccessful) error(httpMessage("BookOrbit book detail failed", response))
        response.body()?.toBook(fallbackLibraryId) ?: error("BookOrbit returned an empty book detail")
    }

    suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = runSuspendCatching {
        if (book.audioTracks.hasSeekableOffsets()) return@runSuspendCatching book.audioTracks
        getBook(book.id, book.libraryId).getOrThrow().audioTracks
    }

    suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runSuspendCatching {
        val detailed = getBook(book.id, book.libraryId).getOrElse { book }
        val tracks = detailed.audioTracks.ifEmpty { book.audioTracks }
        if (tracks.isEmpty()) error("BookOrbit returned no playable audio tracks")
        ProviderPlaybackSession(
            sessionId = "bookorbit:${book.id}",
            audioTracks = tracks,
            chapters = detailed.chapters.ifEmpty { synthesizeChapters(tracks, detailed.duration.takeIf { it > 0 } ?: book.duration) },
        )
    }

    suspend fun syncAudiobookProgress(
        book: Book,
        currentTimeSec: Long,
        progressFraction: Float,
    ): Result<Unit> = runSuspendCatching {
        val bookId = book.id.toIntOrNull() ?: return@runSuspendCatching
        val (fileId, localPositionSec) = currentFileAndOffset(book, currentTimeSec)
        val id = fileId ?: return@runSuspendCatching
        val percentage = (progressFraction * 100.0).coerceIn(0.0, 100.0)
        val response = api.updateAudioProgress(
            bookId = bookId,
            request = BookOrbitAudioProgressRequest(
                percentage = percentage,
                currentFileId = id,
                positionSeconds = localPositionSec.coerceAtLeast(0L).toDouble(),
            ),
        )
        if (!response.isSuccessful) error(httpMessage("BookOrbit audio progress sync failed", response))
    }

    suspend fun fetchAudiobookProgress(book: Book): Result<SyncSnapshot?> = runSuspendCatching {
        fetchDirectAudiobookProgress(book) ?: fetchCurrentlyReadingAudiobookProgress(book)
    }

    private suspend fun fetchDirectAudiobookProgress(book: Book): SyncSnapshot? {
        val bookId = book.id.toIntOrNull() ?: return null
        val response = api.audioProgress(bookId)
        if (response.code() == 404 || response.code() == 204) return null
        if (!response.isSuccessful) error(httpMessage("BookOrbit audio progress pull failed", response))
        val dto = response.body() ?: return null
        val fileId = dto.currentFileId
            ?: return progressSnapshotFromPercentage(
                book = book,
                percentagePercent = dto.percentage,
                updatedAt = parseDateMillis(dto.updatedAt),
            )
        val localPosition = (dto.positionSeconds ?: 0.0).roundToLong()
        val tracks = getAudioTracks(book).getOrDefault(emptyList())
        val track = tracks.firstOrNull { it.fileId?.toIntOrNull() == fileId }
        val global = (track?.cumulativeStartMs ?: 0L) / 1000L + localPosition
        val percentage = ((dto.percentage ?: 0.0) / 100.0).toFloat().coerceIn(0f, 1f)
        val durationSec = durationForProgress(book, tracks)
        return SyncSnapshot(
            percentage = if (percentage > 0.001f || durationSec <= 0L) {
                percentage
            } else {
                (global.toFloat() / durationSec.toFloat()).coerceIn(0f, 1f)
            },
            positionMs = global * 1000L,
            locatorJson = null,
            updatedAt = parseDateMillis(dto.updatedAt),
            source = BookSource.BOOKORBIT.displayName,
        )
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
        if (!response.isSuccessful) error(httpMessage("BookOrbit ebook progress sync failed", response))
    }

    suspend fun fetchEbookProgress(book: Book): Result<SyncSnapshot?> = runSuspendCatching {
        val fileId = primaryEbookFileId(book.id) ?: return@runSuspendCatching null
        fetchDirectEbookProgress(fileId)
    }

    private suspend fun fetchDirectEbookProgress(fileId: Int): SyncSnapshot? {
        val response = api.ebookProgress(fileId)
        if (response.code() == 404 || response.code() == 204) return null
        if (!response.isSuccessful) error(httpMessage("BookOrbit ebook progress pull failed", response))
        val dto = response.body() ?: return null
        val cfi = dto.cfi?.takeIf(EpubBridgeCheckpointCodec::isFullEpubCfi)
        return SyncSnapshot(
            percentage = ((dto.percentage ?: 0.0) / 100.0).toFloat().coerceIn(0f, 1f),
            epubCfi = cfi,
            updatedAt = parseDateMillis(dto.updatedAt),
            source = BookSource.BOOKORBIT.displayName,
        )
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
        if (!response.isSuccessful) error(httpMessage("BookOrbit read status update failed", response))
    }

    suspend fun updatePersonalRating(bookId: String, rating: Int): Result<Unit> = runSuspendCatching {
        val id = bookId.toIntOrNull() ?: error("Invalid BookOrbit book id")
        val response = api.updateRating(id, BookOrbitRatingRequest(rating.coerceIn(1, 5)))
        if (!response.isSuccessful) error(httpMessage("BookOrbit rating update failed", response))
    }

    suspend fun pushAnnotations(
        book: Book,
        annotations: List<ReaderAnnotation>,
    ): Result<AnnotationsPushResult> = runSuspendCatching {
        val bookId = book.id.toIntOrNull() ?: error("Invalid BookOrbit book id")
        val accepted = mutableListOf<AcceptedAnnotation>()
        val rejected = mutableListOf<RejectedAnnotation>()
        for (annotation in annotations) {
            if (annotation.providerSource != "bookorbit") {
                rejected += RejectedAnnotation(annotation.id, "Reader artifact belongs to another provider")
                continue
            }
            if (annotation.deletedAt != null) {
                try {
                    annotation.serverId?.let { deleteRemoteArtifact(bookId, it) }
                    accepted += AcceptedAnnotation(annotation.id, annotation.serverId)
                } catch (t: Throwable) {
                    if (t is kotlinx.coroutines.CancellationException) throw t
                    rejected += RejectedAnnotation(annotation.id, t.message ?: "BookOrbit deletion failed")
                }
                continue
            }
            if (annotation.isBookOrbitBookmark()) {
                try {
                    annotation.serverId?.let { deleteRemoteArtifact(bookId, it) }
                    val response = api.createBookmark(
                        bookId,
                        BookOrbitBookmarkRequest(
                            cfi = if (AnnotationMedia.parse(annotation.media) == AnnotationMedia.EPUB) {
                                annotation.bookOrbitCfi()
                            } else {
                                null
                            },
                            title = annotation.bookOrbitBookmarkTitle(),
                            positionSeconds = annotation.audioPositionMs?.div(1_000.0),
                        ),
                    )
                    if (!response.isSuccessful) error(httpMessage("BookOrbit bookmark sync failed", response))
                    val remote = response.body() ?: error("BookOrbit returned an empty bookmark response")
                    accepted += AcceptedAnnotation(annotation.id, "bookmark:${remote.id}")
                } catch (t: Throwable) {
                    if (t is kotlinx.coroutines.CancellationException) throw t
                    rejected += RejectedAnnotation(annotation.id, t.message ?: "BookOrbit bookmark sync failed")
                }
                continue
            }
            if (!annotation.isBookOrbitHighlight()) {
                accepted += AcceptedAnnotation(annotation.id, annotation.serverId)
                continue
            }
            try {
                val response = annotation.serverId?.toIntOrNull()?.let { serverId ->
                    api.updateAnnotation(
                        bookId,
                        serverId,
                        BookOrbitUpdateAnnotationRequest(
                            note = annotation.note.takeIf { it.isNotBlank() },
                            color = annotation.colorHex,
                            style = annotation.bookOrbitStyle(),
                        ),
                    )
                } ?: api.createAnnotation(
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
                if (!response.isSuccessful) error(httpMessage("BookOrbit annotation sync failed", response))
                val remote = response.body() ?: error("BookOrbit returned an empty annotation response")
                accepted += AcceptedAnnotation(annotation.id, remote.id.toString())
            } catch (t: Throwable) {
                if (t is kotlinx.coroutines.CancellationException) throw t
                rejected += RejectedAnnotation(annotation.id, t.message ?: "BookOrbit annotation sync failed")
            }
        }
        AnnotationsPushResult(accepted = accepted, rejected = rejected)
    }

    suspend fun fetchAnnotations(book: Book): Result<List<ReaderAnnotation>> = runSuspendCatching {
        val bookId = book.id.toIntOrNull() ?: error("Invalid BookOrbit book id")
        coroutineScope {
            val annotations = async { api.annotations(bookId) }
            val bookmarks = async { api.bookmarks(bookId) }
            val annotationResponse = annotations.await()
            val bookmarkResponse = bookmarks.await()
            if (!annotationResponse.isSuccessful) error(httpMessage("BookOrbit annotations failed", annotationResponse))
            if (!bookmarkResponse.isSuccessful) error(httpMessage("BookOrbit bookmarks failed", bookmarkResponse))
            annotationResponse.body().orEmpty().map { it.toReaderAnnotation(book.id) } +
                bookmarkResponse.body().orEmpty().map { it.toReaderAnnotation(book.id) }
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
        if (!response.isSuccessful) error(httpMessage("BookOrbit reading-session sync failed", response))
    }

    suspend fun fetchReadingSessions(book: Book): Result<List<BookOrbitReadingSessionRecord>> = runSuspendCatching {
        val bookId = book.id.toIntOrNull() ?: error("Invalid BookOrbit book id")
        val records = mutableListOf<BookOrbitReadingSessionRecord>()
        var page = 1
        while (true) {
            val response = api.readingSessions(bookId, page = page, pageSize = 100)
            if (!response.isSuccessful) error(httpMessage("BookOrbit reading sessions failed", response))
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

    fun getServeUrl(fileId: Int): String = "${apiBaseUrl()}/books/files/$fileId/serve"

    fun getDownloadUrl(fileId: Int): String = "${apiBaseUrl()}/books/files/$fileId/download"

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
        if (!response.isSuccessful) error(httpMessage("BookOrbit books failed", response))
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
            seriesNumber = seriesIndex?.let(::sequenceString),
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
            addedOn = parseDateMillis(addedAt) ?: 0L,
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
            seriesNumber = seriesIndex?.let(::sequenceString),
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
            addedOn = parseDateMillis(addedAt) ?: 0L,
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
                contentUrl = getServeUrl(file.id),
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

    private fun ReaderAnnotation.isBookOrbitHighlight(): Boolean =
        AnnotationMedia.parse(media) == AnnotationMedia.EPUB &&
            AnnotationKind.parse(kind) != AnnotationKind.BOOKMARK &&
            !cfi.isNullOrBlank() &&
            selectedText.isNotBlank()

    private fun ReaderAnnotation.isBookOrbitBookmark(): Boolean =
        AnnotationKind.parse(kind) == AnnotationKind.BOOKMARK && when (AnnotationMedia.parse(media)) {
            AnnotationMedia.AUDIOBOOK -> audioPositionMs != null
            AnnotationMedia.EPUB -> !cfi.isNullOrBlank()
            else -> false
        }

    private fun ReaderAnnotation.bookOrbitCfi(): String? = cfi?.takeIf { it.isNotBlank() }?.let {
        if (it.startsWith("epubcfi(")) it else "epubcfi($it)"
    }

    private fun ReaderAnnotation.bookOrbitBookmarkTitle(): String =
        note.takeIf { it.isNotBlank() }
            ?: selectedText.takeIf { it.isNotBlank() }
            ?: chapterId?.takeIf { it.isNotBlank() }
            ?: "Bookmark"

    private fun ReaderAnnotation.bookOrbitStyle(): String = when (AnnotationStyle.parse(style)) {
        AnnotationStyle.UNDERLINE -> "underline"
        AnnotationStyle.STRIKETHROUGH -> "strikethrough"
        AnnotationStyle.SQUIGGLY -> "squiggly"
        AnnotationStyle.HIGHLIGHT, AnnotationStyle.NONE -> "highlight"
    }

    private fun BookOrbitAnnotationDto.toReaderAnnotation(localBookId: String): ReaderAnnotation {
        val created = parseDateMillis(createdAt) ?: System.currentTimeMillis()
        return ReaderAnnotation(
            id = "bookorbit:$id",
            bookId = localBookId,
            kind = if (note.isNullOrBlank()) AnnotationKind.HIGHLIGHT.name else AnnotationKind.NOTE.name,
            media = AnnotationMedia.EPUB.name,
            style = when (style.lowercase()) {
                "underline" -> AnnotationStyle.UNDERLINE.name
                "strikethrough" -> AnnotationStyle.STRIKETHROUGH.name
                "squiggly" -> AnnotationStyle.SQUIGGLY.name
                else -> AnnotationStyle.HIGHLIGHT.name
            },
            colorHex = color,
            cfi = cfi,
            selectedText = text,
            note = note.orEmpty(),
            chapterId = chapterTitle,
            createdAt = created,
            updatedAt = created,
            serverId = id.toString(),
            providerSource = "bookorbit",
            syncDirty = false,
        )
    }

    private fun BookOrbitBookmarkDto.toReaderAnnotation(localBookId: String): ReaderAnnotation {
        val created = parseDateMillis(createdAt) ?: System.currentTimeMillis()
        val media = if (positionSeconds != null) AnnotationMedia.AUDIOBOOK else AnnotationMedia.EPUB
        return ReaderAnnotation(
            id = "bookorbit:bookmark:$id",
            bookId = localBookId,
            kind = AnnotationKind.BOOKMARK.name,
            media = media.name,
            style = AnnotationStyle.NONE.name,
            colorHex = "#F5921A",
            audioPositionMs = positionSeconds?.times(1_000.0)?.roundToLong(),
            cfi = cfi,
            selectedText = title,
            createdAt = created,
            updatedAt = created,
            serverId = "bookmark:$id",
            providerSource = "bookorbit",
            syncDirty = false,
        )
    }

    private suspend fun deleteRemoteArtifact(bookId: Int, serverId: String) {
        val bookmarkId = serverId.removePrefix("bookmark:").toIntOrNull()
        val response = if (serverId.startsWith("bookmark:") && bookmarkId != null) {
            api.deleteBookmark(bookId, bookmarkId)
        } else {
            val annotationId = serverId.toIntOrNull() ?: return
            api.deleteAnnotation(bookId, annotationId)
        }
        if (!response.isSuccessful && response.code() != 404) {
            error(httpMessage("BookOrbit reader-artifact deletion failed", response))
        }
    }

    private fun BookOrbitReadingSessionDto.toRecord(fallback: AppMediaType): BookOrbitReadingSessionRecord? {
        val started = parseDateMillis(startedAt) ?: return null
        val ended = parseDateMillis(endedAt) ?: return null
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

    private fun sequenceString(value: Double): String =
        if (value % 1.0 == 0.0) value.toInt().toString() else value.toString()

    private fun parseDateMillis(raw: String?): Long? {
        if (raw.isNullOrBlank()) return null
        return runCatching { Instant.parse(raw).toEpochMilli() }.getOrNull()
            ?: runCatching { OffsetDateTime.parse(raw).toInstant().toEpochMilli() }.getOrNull()
            ?: runCatching { LocalDateTime.parse(raw, DateTimeFormatter.ISO_DATE_TIME).toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull()
            ?: runCatching { LocalDate.parse(raw, DateTimeFormatter.ISO_DATE).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull()
            ?: raw.toLongOrNull()?.let { if (it > 1_000_000_000_000L) it else it * 1000L }
    }

    private fun httpMessage(prefix: String, response: Response<*>): String =
        "$prefix: HTTP ${response.code()} ${response.message()}".trim()

    private enum class ContinueKind { LISTENING, READING }

    private companion object {
        const val SERVER_PAGE_SIZE = 200
        const val SERVER_PAGE_CEILING = 250
    }
}
