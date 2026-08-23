package com.enve.storyteller

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.storyteller.StorytellerRepository
import com.enve.core.data.sync.SyncCapability
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderMetadataUpdate
import com.enve.core.data.provider.ProviderPlaybackSession
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class StorytellerProviderAdapter @Inject constructor(
    private val repository: StorytellerRepository,
) : ProviderAdapter {
    override val source: BookSource = BookSource.STORYTELLER
    override val syncCapability: SyncCapability = SyncCapability.READ_WRITE
    override val supportsMetadataUpdate: Boolean = true
    override val supportsPersonalRating: Boolean = true

    override suspend fun getLibraries(): Result<List<Library>> = repository.getLibraries()

    override suspend fun getBooks(libraryId: String?, page: Int, size: Int, sort: String, dir: String): Result<List<Book>> =
        repository.getBooks()

    override suspend fun getContinueListening(): Result<List<Book>> = repository.getContinueListening()

    override suspend fun getContinueReading(): Result<List<Book>> = repository.getContinueReading()

    override suspend fun getRecentlyAdded(): Result<List<Book>> = repository.getRecentlyAdded()

    override suspend fun getEbookDownloadUrl(bookId: String): String? = repository.getEbookDownloadUrl(bookId)

    override suspend fun getReadaloudDownloadUrl(bookId: String): String? = repository.getReadaloudDownloadUrl(bookId)

    override suspend fun updateBookStatus(bookId: String, status: String): Result<Unit> =
        repository.updateBookStatus(bookId, status)

    override suspend fun updatePersonalRating(bookId: String, rating: Int): Result<Unit> =
        repository.updatePersonalRating(bookId, rating)

    override suspend fun updateBookMetadata(
        book: Book,
        metadata: ProviderMetadataUpdate,
    ): Result<Unit> = repository.updateBookMetadata(book, metadata)

    override suspend fun getAudioTracks(book: Book): Result<List<com.enve.core.data.model.AudioTrack>> =
        repository.startPlaybackSession(book).mapCatching { it.audioTracks }

    override suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = repository.startPlaybackSession(book)

    override suspend fun fetchChapters(book: Book): Result<List<Chapter>> =
        repository.startPlaybackSession(book).mapCatching { it.chapters }

    override suspend fun syncAudiobookProgress(book: Book, currentTimeSec: Long, progressFraction: Float): Result<Unit> =
        repository.syncAudiobookProgress(book, currentTimeSec, progressFraction)

    override suspend fun syncEbookProgress(bookId: String, percentage: Float, locator: String?, page: Int?, pageCount: Int?): Result<Unit> =
        repository.syncEbookProgress(bookId, percentage, locator)

    override suspend fun fetchAudiobookProgress(book: Book): Result<SyncSnapshot?> = repository.fetchAudiobookProgress(book)

    override suspend fun fetchEbookProgress(book: Book): Result<SyncSnapshot?> = repository.fetchEbookProgress(book)

    override fun invalidateCaches() = repository.invalidateListCaches()

    override suspend fun getSeries(): Result<List<com.enve.core.data.remote.dto.SeriesSummaryDto>> = repository.getSeries()

    override suspend fun getAuthors(): Result<List<com.enve.core.data.remote.dto.AuthorSummaryDto>> = repository.getAuthors()
}
