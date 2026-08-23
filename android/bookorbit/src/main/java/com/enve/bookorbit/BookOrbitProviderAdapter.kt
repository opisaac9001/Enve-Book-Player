package com.enve.bookorbit

import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderEbookResource
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.sync.SyncCapability
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.sync.AnnotationsPushResult
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BookOrbitProviderAdapter @Inject constructor(
    private val repository: BookOrbitRepository,
) : ProviderAdapter {
    override val source: BookSource = BookSource.BOOKORBIT
    override val syncCapability: SyncCapability = SyncCapability.FULL
    override val supportsPersonalRating: Boolean = true
    override val annotationsAreAuthoritative: Boolean = true

    override suspend fun getLibraries(): Result<List<Library>> = repository.getLibraries()

    override suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): Result<List<Book>> = repository.getBooks(libraryId = libraryId, page = page, size = size)

    override suspend fun getContinueListening(): Result<List<Book>> = repository.getContinueListening()

    override suspend fun getContinueReading(): Result<List<Book>> = repository.getContinueReading()

    override suspend fun getRecentlyAdded(): Result<List<Book>> = repository.getRecentlyAdded()

    override suspend fun getEbookDownloadUrl(bookId: String): String? = repository.getEbookDownloadUrl(bookId)

    override suspend fun getEbookResource(bookId: String): ProviderEbookResource? =
        repository.getEbookResource(bookId)

    override suspend fun updateBookStatus(bookId: String, status: String): Result<Unit> =
        repository.updateBookStatus(bookId, status)

    override suspend fun updatePersonalRating(bookId: String, rating: Int): Result<Unit> =
        repository.updatePersonalRating(bookId, rating)

    override suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = repository.getAudioTracks(book)

    override suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> =
        repository.startPlaybackSession(book)

    override suspend fun fetchChapters(book: Book): Result<List<Chapter>> =
        repository.startPlaybackSession(book).mapCatching { it.chapters }

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

    override suspend fun pushAnnotations(
        book: Book,
        annotations: List<ReaderAnnotation>,
    ): Result<AnnotationsPushResult> = repository.pushAnnotations(book, annotations)

    override suspend fun fetchAnnotations(
        book: Book,
        sinceUpdatedAt: Long?,
    ): Result<List<ReaderAnnotation>> = repository.fetchAnnotations(book)

    override suspend fun deleteRemoteAnnotation(book: Book, serverId: String): Result<Unit> =
        repository.deleteRemoteAnnotation(book, serverId)

    override suspend fun validateConnection(): Result<Boolean> = repository.validateConnection()

    override fun invalidateCaches() = repository.invalidateCaches()
}
