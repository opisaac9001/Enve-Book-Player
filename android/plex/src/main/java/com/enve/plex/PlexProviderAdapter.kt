package com.enve.plex

import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.sync.SyncCapability
import com.enve.core.data.sync.SyncSnapshot
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PlexProviderAdapter @Inject constructor(
    private val repository: PlexRepository,
) : ProviderAdapter {

    override val source: BookSource = BookSource.PLEX
    override val syncCapability: SyncCapability = SyncCapability.READ_WRITE

    override suspend fun getLibraries(): Result<List<Library>> =
        repository.getLibraries()

    override suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): Result<List<Book>> = repository.getBooks(libraryId)

    override suspend fun getContinueListening(): Result<List<Book>> =
        repository.getOnDeck()

    override suspend fun getContinueReading(): Result<List<Book>> = Result.success(emptyList())

    override suspend fun getRecentlyAdded(): Result<List<Book>> =
        repository.getRecentlyAdded()

    override suspend fun getEbookDownloadUrl(bookId: String): String? = null

    override suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> =
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

    override suspend fun fetchAudiobookProgress(book: Book): Result<SyncSnapshot?> =
        repository.fetchAudiobookProgress(book)

    override suspend fun resetBookProgress(book: Book): Result<Unit> =
        repository.resetBookProgress(book)

    override fun invalidateCaches() {

    }
}
