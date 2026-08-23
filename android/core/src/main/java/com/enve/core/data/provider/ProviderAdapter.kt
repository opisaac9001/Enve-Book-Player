package com.enve.core.data.provider

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.sync.AnnotationsPushResult
import com.enve.core.data.sync.SyncCapability
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.util.runSuspendCatching

data class ProviderPlaybackSession(
    val sessionId: String,
    val audioTracks: List<com.enve.core.data.model.AudioTrack> = emptyList(),
    val chapters: List<Chapter> = emptyList(),
    val serverCurrentTimeSec: Long? = null,
)

data class ProviderMetadataUpdate(
    val title: String,
    val subtitle: String? = null,
    val author: String? = null,
    val narrator: String? = null,
    val description: String? = null,
    val seriesName: String? = null,
    val seriesNumber: String? = null,
    val publisher: String? = null,
    val publishedDate: String? = null,
    val isbn13: String? = null,
    val language: String? = null,
    val pageCount: Int? = null,
    val categories: List<String> = emptyList(),
)

data class ProviderEbookResource(
    val url: String,
    val providerFileId: String? = null,
    val format: String = "EPUB",
)

interface ProviderAdapter {
    val source: BookSource

    val syncCapability: SyncCapability get() = SyncCapability.NONE

    val supportsMetadataUpdate: Boolean get() = false
    val supportsLibraryMetadataRefresh: Boolean get() = false
    val supportsPersonalRating: Boolean get() = false
    val annotationsAreAuthoritative: Boolean get() = false

    suspend fun getLibraries(): Result<List<Library>>

    suspend fun getBooks(
        libraryId: String? = null,
        page: Int = 0,
        size: Int = 50,
        sort: String = "addedOn",
        dir: String = "desc",
    ): Result<List<Book>>

    suspend fun getContinueListening(): Result<List<Book>>

    suspend fun getContinueReading(): Result<List<Book>>

    suspend fun getRecentlyAdded(): Result<List<Book>>

    suspend fun getEbookDownloadUrl(bookId: String): String?

    suspend fun getEbookResource(bookId: String): ProviderEbookResource? =
        getEbookDownloadUrl(bookId)?.let(::ProviderEbookResource)

    suspend fun getReadaloudDownloadUrl(bookId: String): String? = getEbookDownloadUrl(bookId)

    suspend fun updateBookStatus(bookId: String, status: String): Result<Unit> = Result.success(Unit)

    suspend fun updatePersonalRating(bookId: String, rating: Int): Result<Unit> =
        Result.failure(UnsupportedOperationException("${source.displayName} ratings are not supported"))

    suspend fun resetBookProgress(book: Book): Result<Unit> = when (book.mediaType) {
        com.enve.core.data.model.AppMediaType.AUDIOBOOK ->
            syncAudiobookProgress(book, currentTimeSec = 0L, progressFraction = 0f)
        com.enve.core.data.model.AppMediaType.EBOOK ->
            syncEbookProgress(book.id, percentage = 0f, locator = null, page = null, pageCount = null)
        else -> Result.success(Unit)
    }

    suspend fun markSeriesRead(seriesId: String): Result<Unit> = Result.success(Unit)
    suspend fun markSeriesUnread(seriesId: String): Result<Unit> = Result.success(Unit)

    suspend fun getComicReadingDirection(book: Book): Result<String?> = Result.success(null)

    suspend fun getAudioTracks(book: Book): Result<List<com.enve.core.data.model.AudioTrack>> = Result.success(emptyList())

    suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runSuspendCatching {
        val tracks = getAudioTracks(book).getOrThrow()
        ProviderPlaybackSession(
            sessionId = "${source.name.lowercase()}-${book.id}",
            audioTracks = tracks,
            chapters = synthesizeChaptersFromTracks(tracks, book.duration),
        )
    }

    suspend fun fetchChapters(book: Book): Result<List<Chapter>> = runSuspendCatching {
        if (book.chapters.isNotEmpty()) return@runSuspendCatching book.chapters
        val session = startPlaybackSession(book).getOrThrow()
        session.chapters.ifEmpty { synthesizeChaptersFromTracks(session.audioTracks, book.duration) }
    }

    suspend fun syncAudiobookProgress(
        book: Book,
        currentTimeSec: Long,
        progressFraction: Float,
    ): Result<Unit> = Result.success(Unit)

    suspend fun syncEbookProgress(
        bookId: String,
        percentage: Float,
        locator: String?,
        page: Int? = null,
        pageCount: Int? = null,
    ): Result<Unit> = Result.success(Unit)

    suspend fun fetchAudiobookProgress(book: Book): Result<SyncSnapshot?> = Result.success(null)

    suspend fun fetchEbookProgress(book: Book): Result<SyncSnapshot?> = Result.success(null)

    suspend fun pushAnnotations(
        book: Book,
        annotations: List<ReaderAnnotation>,
    ): Result<AnnotationsPushResult> = Result.success(AnnotationsPushResult())

    suspend fun fetchAnnotations(
        book: Book,
        sinceUpdatedAt: Long? = null,
    ): Result<List<ReaderAnnotation>> = Result.success(emptyList())

    suspend fun deleteRemoteAnnotation(
        book: Book,
        serverId: String,
    ): Result<Unit> = Result.success(Unit)

    suspend fun fetchAudiobookNarrator(book: Book): Result<String?> = Result.success(null)

    suspend fun updateBookMetadata(
        book: Book,
        metadata: ProviderMetadataUpdate,
    ): Result<Unit> = Result.failure(UnsupportedOperationException("${source.displayName} metadata updates are not supported"))

    suspend fun deleteBook(book: Book): Result<Unit> =
        Result.failure(UnsupportedOperationException("${source.displayName} book deletion is not supported"))

    suspend fun refreshLibraryMetadata(libraryId: String): Result<Unit> =
        Result.failure(UnsupportedOperationException("${source.displayName} library metadata refresh is not supported"))

    fun invalidateCaches()

    suspend fun validateConnection(): Result<Boolean> = getLibraries().map { true }

    suspend fun getSeries(): Result<List<com.enve.core.data.remote.dto.SeriesSummaryDto>> = Result.success(emptyList())
    suspend fun getAuthors(): Result<List<com.enve.core.data.remote.dto.AuthorSummaryDto>> = Result.success(emptyList())
    suspend fun getShelves(): Result<List<com.enve.core.data.model.Shelf>> = Result.success(emptyList())
    suspend fun getShelfBooks(shelfId: String): Result<List<Book>> = Result.success(emptyList())
}

fun synthesizeChaptersFromTracks(
    tracks: List<com.enve.core.data.model.AudioTrack>,
    durationSec: Long,
): List<Chapter> {
    if (tracks.size <= 1) return emptyList()

    var runningStartMs = 0L
    return tracks.sortedBy { it.index }.mapIndexed { index, track ->
        val startMs = track.cumulativeStartMs.takeIf { it > 0L } ?: runningStartMs
        val endMs = when {
            track.durationMs > 0L -> startMs + track.durationMs
            index == tracks.lastIndex && durationSec > 0L -> durationSec * 1000L
            else -> startMs
        }
        runningStartMs = endMs
        Chapter(
            index = index,
            title = track.title?.takeIf { it.isNotBlank() } ?: track.fileName.ifBlank { "Track ${index + 1}" },
            startTime = startMs / 1000L,
            endTime = (endMs / 1000L).coerceAtLeast(startMs / 1000L),
        )
    }
}
