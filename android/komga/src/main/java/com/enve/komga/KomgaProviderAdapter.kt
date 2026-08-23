package com.enve.komga

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.komga.KomgaRepository
import com.enve.core.data.sync.SyncCapability
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderMetadataUpdate
import com.enve.core.data.util.runSuspendCatching
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class KomgaProviderAdapter @Inject constructor(
    private val repository: KomgaRepository,
) : ProviderAdapter {
    override val source: BookSource = BookSource.KOMGA
    override val syncCapability: SyncCapability = SyncCapability.READ_WRITE
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

    override suspend fun getEbookDownloadUrl(bookId: String): String? =
        repository.getEbookDownloadUrl(bookId)

    override suspend fun updateBookMetadata(
        book: Book,
        metadata: ProviderMetadataUpdate,
    ): Result<Unit> = repository.updateBookMetadata(book, metadata)

    override suspend fun refreshLibraryMetadata(libraryId: String): Result<Unit> =
        repository.adminRefreshLibraryMetadata(libraryId)

    override suspend fun getAudioTracks(book: Book): Result<List<com.enve.core.data.model.AudioTrack>> =
        repository.getAudioTracks(book)

    override suspend fun syncEbookProgress(
        bookId: String,
        percentage: Float,
        locator: String?,
        page: Int?,
        pageCount: Int?,
    ): Result<Unit> = repository.syncEbookProgress(
        bookId = bookId,
        percentage = percentage,
        page = page,
        pageCount = pageCount,
    )

    override suspend fun fetchEbookProgress(book: Book): Result<SyncSnapshot?> =
        repository.fetchEbookProgress(book)

    override fun invalidateCaches() {
        repository.invalidateListCaches()
    }

    override suspend fun getSeries(): Result<List<com.enve.core.data.remote.dto.SeriesSummaryDto>> =
        repository.getSeries()

    override suspend fun getAuthors(): Result<List<com.enve.core.data.remote.dto.AuthorSummaryDto>> =
        repository.getAuthors()

    override suspend fun resetBookProgress(book: Book): Result<Unit> =
        repository.markBookUnread(book.id)

    override suspend fun updateBookStatus(bookId: String, status: String): Result<Unit> =
        when (status.uppercase()) {
            "READ", "COMPLETED" -> repository.markBookCompleted(bookId)
            "UNREAD" -> repository.markBookUnread(bookId)
            else -> Result.success(Unit)
        }

    override suspend fun markSeriesRead(seriesId: String): Result<Unit> =
        repository.markSeriesRead(seriesId)

    override suspend fun markSeriesUnread(seriesId: String): Result<Unit> =
        repository.markSeriesUnread(seriesId)

    override suspend fun getComicReadingDirection(book: Book): Result<String?> =
        runSuspendCatching { repository.getReadingDirectionForBook(book.id) }
}
