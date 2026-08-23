package com.enve.app.data.provider

import com.enve.app.data.repository.GrimmoryRepository
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderPlaybackSession
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class WebDavProviderAdapter @Inject constructor(
    private val repository: GrimmoryRepository,
) : ProviderAdapter {
    override val source: BookSource = BookSource.WEBDAV

    override suspend fun getLibraries(): Result<List<Library>> =
        repository.getLibrariesForSource(source)

    override suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): Result<List<Book>> = repository.getBooksForSource(source, libraryId, page, size, sort, dir)

    override suspend fun getContinueListening(): Result<List<Book>> =
        repository.getContinueListeningForSource(source)

    override suspend fun getContinueReading(): Result<List<Book>> =
        repository.getContinueReadingForSource(source)

    override suspend fun getRecentlyAdded(): Result<List<Book>> =
        repository.getRecentlyAddedForSource(source)

    override suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = runCatching {
        if (book.mediaType != AppMediaType.AUDIOBOOK) return@runCatching emptyList()
        listOf(
            AudioTrack(
                index = 0,
                fileName = book.title,
                title = book.title,
                durationMs = book.duration * 1000L,
                fileSizeBytes = 0L,
                cumulativeStartMs = 0L,
                contentUrl = book.id,
            )
        )
    }

    override suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runCatching {
        ProviderPlaybackSession(
            sessionId = "webdav-${book.id}",
            audioTracks = getAudioTracks(book).getOrThrow(),
            chapters = book.chapters,
        )
    }

    override suspend fun getEbookDownloadUrl(bookId: String): String? = bookId

    override fun invalidateCaches() {
        repository.invalidateListCaches()
    }
}
