package com.enve.audiobookshelf

import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.core.data.model.ReaderAnnotation
import com.enve.audiobookshelf.AudiobookshelfRepository
import com.enve.core.data.sync.AcceptedAnnotation
import com.enve.core.data.sync.AnnotationsPushResult
import com.enve.core.data.sync.RejectedAnnotation
import com.enve.core.data.sync.SyncCapability
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderMetadataUpdate
import com.enve.core.data.provider.ProviderPlaybackSession
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AudiobookshelfProviderAdapter @Inject constructor(
    private val repository: AudiobookshelfRepository,
) : ProviderAdapter {
    override val source: BookSource = BookSource.AUDIOBOOKSHELF
    override val syncCapability: SyncCapability = SyncCapability.FULL
    override val supportsMetadataUpdate: Boolean = true
    override val supportsLibraryMetadataRefresh: Boolean = true

    override suspend fun getLibraries(): Result<List<Library>> =
        repository.getLibraries()

    override suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): Result<List<Book>> = repository.getBooks(
        libraryId = libraryId,
        page = page,
        size = size,
        sort = sort,
        dir = dir,
    )

    override suspend fun getContinueListening(): Result<List<Book>> =
        repository.getContinueListening()

    override suspend fun getContinueReading(): Result<List<Book>> =
        repository.getContinueReading()

    override suspend fun getRecentlyAdded(): Result<List<Book>> =
        repository.getRecentlyAdded()

    override suspend fun getAudioTracks(book: Book): Result<List<com.enve.core.data.model.AudioTrack>> =
        repository.getAudioTracks(book)

    override suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> =
        repository.startPlaybackSession(book)

    override suspend fun fetchChapters(book: Book): Result<List<Chapter>> =
        repository.fetchChapters(book)

    override suspend fun syncAudiobookProgress(
        book: Book,
        currentTimeSec: Long,
        progressFraction: Float,
    ): Result<Unit> = repository.syncAudiobookProgress(book, currentTimeSec, progressFraction)

    override suspend fun syncEbookProgress(
        bookId: String,
        percentage: Float,
        locator: String?,
        page: Int?,
        pageCount: Int?,
    ): Result<Unit> = repository.syncEbookProgress(bookId, percentage, locator)

    override suspend fun fetchAudiobookProgress(book: Book): Result<SyncSnapshot?> =
        repository.fetchAudiobookProgress(book)

    override suspend fun fetchEbookProgress(book: Book): Result<SyncSnapshot?> =
        repository.fetchEbookProgress(book)

    override suspend fun getEbookDownloadUrl(bookId: String): String? =
        repository.getEbookDownloadUrl(bookId)

    override suspend fun updateBookMetadata(
        book: Book,
        metadata: ProviderMetadataUpdate,
    ): Result<Unit> = repository.updateBookMetadata(book, metadata)

    override suspend fun refreshLibraryMetadata(libraryId: String): Result<Unit> =
        repository.matchAllLibraryMetadata(libraryId)

    override fun invalidateCaches() {
        repository.invalidateListCaches()
    }

    override suspend fun getSeries(): Result<List<com.enve.core.data.remote.dto.SeriesSummaryDto>> =
        repository.getSeries()

    override suspend fun getAuthors(): Result<List<com.enve.core.data.remote.dto.AuthorSummaryDto>> =
        repository.getAuthors()

    override suspend fun pushAnnotations(
        book: Book,
        annotations: List<ReaderAnnotation>,
    ): Result<AnnotationsPushResult> = runCatching {
        val accepted = mutableListOf<AcceptedAnnotation>()
        val rejected = mutableListOf<RejectedAnnotation>()
        for (a in annotations) {
            val isAudiobookBookmark = AnnotationKind.parse(a.kind) == AnnotationKind.BOOKMARK &&
                AnnotationMedia.parse(a.media) == AnnotationMedia.AUDIOBOOK &&
                a.audioPositionMs != null
            if (!isAudiobookBookmark) {

                accepted += AcceptedAnnotation(id = a.id, serverId = null)
                continue
            }
            val title = a.note.ifBlank { a.selectedText.ifBlank { "Bookmark" } }
                .take(140)
            val timeSec = (a.audioPositionMs!! / 1000.0)
            try {
                val request = com.enve.audiobookshelf.dto.AbsBookmarkRequest(title = title, time = timeSec)
                val resp = if (a.serverId == null) {
                    repository.createBookmark(book.id, request)
                } else {

                    repository.updateBookmark(book.id, request)
                }
                accepted += AcceptedAnnotation(
                    id = a.id,
                    serverId = "${book.id}@${resp.time}",
                )
            } catch (t: Throwable) {
                if (t is kotlinx.coroutines.CancellationException) throw t
                rejected += RejectedAnnotation(id = a.id, reason = t.message ?: t::class.simpleName.orEmpty())
            }
        }
        AnnotationsPushResult(accepted = accepted, rejected = rejected)
    }

    override suspend fun fetchAnnotations(
        book: Book,
        sinceUpdatedAt: Long?,
    ): Result<List<ReaderAnnotation>> = runCatching {

        if (book.mediaType != AppMediaType.AUDIOBOOK) return@runCatching emptyList()
        val me = repository.getMe().getOrNull() ?: return@runCatching emptyList()
        me.bookmarks.asSequence()
            .filter { it.libraryItemId == book.id }
            .map { bm ->
                val now = System.currentTimeMillis()
                val createdMs = bm.createdAt ?: now
                ReaderAnnotation(
                    id = "abs:${book.id}:${bm.time}",
                    bookId = book.id,
                    kind = AnnotationKind.BOOKMARK.name,
                    media = AnnotationMedia.AUDIOBOOK.name,
                    style = com.enve.core.data.model.AnnotationStyle.NONE.name,
                    audioPositionMs = (bm.time * 1000).toLong(),
                    selectedText = "",
                    note = bm.title,
                    createdAt = createdMs,
                    updatedAt = createdMs,
                    providerSource = "audiobookshelf",
                    serverId = "${book.id}@${bm.time}",
                    syncDirty = false,
                )
            }
            .toList()
    }

    override suspend fun deleteRemoteAnnotation(
        book: Book,
        serverId: String,
    ): Result<Unit> = runCatching {

        val time = serverId.substringAfterLast('@', "").toDoubleOrNull()
            ?: return@runCatching
        repository.deleteBookmark(book.id, time)
    }
}
