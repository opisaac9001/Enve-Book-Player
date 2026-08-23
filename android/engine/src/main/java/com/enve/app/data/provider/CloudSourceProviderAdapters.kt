package com.enve.app.data.provider

import com.enve.app.data.repository.GrimmoryRepository
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.provider.synthesizeChaptersFromTracks
import javax.inject.Inject
import javax.inject.Singleton

abstract class CloudSourceProviderAdapter(
    private val repository: GrimmoryRepository,
    private val trackDurations: CloudTrackDurationService,
) : ProviderAdapter {
    protected abstract val sessionPrefix: String

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
        book.audioTracks.takeIf { it.any { track -> !track.contentUrl.isNullOrBlank() } }
            ?: repository.getBooksForSource(source, book.libraryId, page = 0, size = 500)
                .getOrDefault(emptyList())
                .firstOrNull { it.id == book.id }
                ?.audioTracks
                .orEmpty()
    }

    override suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runCatching {
        val tracks = trackDurations.resolveDurations(book, getAudioTracks(book).getOrThrow())
        ProviderPlaybackSession(
            sessionId = "$sessionPrefix-${book.id}",
            audioTracks = tracks,
            chapters = book.chapters.ifEmpty { synthesizeChaptersFromTracks(tracks, book.duration) },
        )
    }

    override suspend fun getEbookDownloadUrl(bookId: String): String? = null

    override fun invalidateCaches() {
        repository.invalidateListCaches()
    }
}

@Singleton
class PremiumizeProviderAdapter @Inject constructor(
    repository: GrimmoryRepository,
    trackDurations: CloudTrackDurationService,
) : CloudSourceProviderAdapter(repository, trackDurations) {
    override val source: BookSource = BookSource.PREMIUMIZE
    override val sessionPrefix: String = "premiumize"
}

@Singleton
class RealDebridProviderAdapter @Inject constructor(
    repository: GrimmoryRepository,
    trackDurations: CloudTrackDurationService,
) : CloudSourceProviderAdapter(repository, trackDurations) {
    override val source: BookSource = BookSource.REALDEBRID
    override val sessionPrefix: String = "realdebrid"
}

@Singleton
class TorBoxProviderAdapter @Inject constructor(
    repository: GrimmoryRepository,
    trackDurations: CloudTrackDurationService,
) : CloudSourceProviderAdapter(repository, trackDurations) {
    override val source: BookSource = BookSource.TORBOX
    override val sessionPrefix: String = "torbox"
}
