package com.enve.app.data.provider

import com.enve.app.data.repository.OpdsRepository
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.BookSummary
import com.enve.core.data.model.Library
import com.enve.core.data.model.ReadStatus
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.remote.ConnectionScope
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OpdsProviderAdapter @Inject constructor(
    private val repository: OpdsRepository,
    private val connectionRegistry: ConnectionRegistry,
    private val prefs: PreferencesManager,
) : ProviderAdapter {
    override val source: BookSource = BookSource.OPDS

    override suspend fun getLibraries(): Result<List<Library>> =
        repository.getLibraries(scopedConnectionId())

    override suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): Result<List<Book>> =
        repository.getItemsPage(scopedConnectionId(), page, size).map { result ->
            result.items.map { it.toBook() }
        }

    override suspend fun getContinueListening(): Result<List<Book>> = Result.success(emptyList())

    override suspend fun getContinueReading(): Result<List<Book>> = Result.success(emptyList())

    override suspend fun getRecentlyAdded(): Result<List<Book>> =
        getBooks(libraryId = "root", page = 0, size = 50, sort = "addedOn", dir = "desc")

    override suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = runCatching {
        if (book.mediaType != AppMediaType.AUDIOBOOK) return@runCatching emptyList()
        listOf(
            AudioTrack(
                index = 0,
                fileName = book.title,
                title = book.title,
                durationMs = 0L,
                contentUrl = book.id,
            )
        )
    }

    override suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runCatching {
        ProviderPlaybackSession(
            sessionId = "opds-${book.id}",
            audioTracks = getAudioTracks(book).getOrThrow(),
            chapters = book.chapters,
        )
    }

    override suspend fun getEbookDownloadUrl(bookId: String): String? = bookId

    override suspend fun validateConnection(): Result<Boolean> =
        repository.getPageByIndex(scopedConnectionId(), 0).map { true }

    override fun invalidateCaches() {
        repository.invalidateCaches()
    }

    private fun scopedConnectionId(): String {
        val scopedId = ConnectionScope.getConnectionId() ?: prefs.getActiveConnectionIdSync()
        if (!scopedId.isNullOrBlank()) return scopedId
        return connectionRegistry.getConnectionsSync().firstOrNull { it.source == BookSource.OPDS }?.id
            ?: error("No OPDS connection selected")
    }

    private fun BookSummary.toBook(): Book = Book(
        id = id,
        title = title,
        author = authors.joinToString(", ").takeIf { it.isNotBlank() },
        coverUrl = thumbnailUrl,
        source = BookSource.OPDS,
        mediaType = mediaType,
        readStatus = readStatus,
        seriesName = seriesName,
        seriesNumber = seriesNumber,
        primaryFileType = primaryFileType,
        libraryId = libraryId,
        connectionId = connectionId,
        addedOn = addedOn,
        lastReadTime = lastReadTime,
        readProgress = readProgress.coerceIn(0f, 1f),
        isFinished = readStatus == ReadStatus.COMPLETED,
        personalRating = personalRating,
        hasAudio = hasAudio || mediaType == AppMediaType.AUDIOBOOK,
        hasEbook = hasEbook || mediaType == AppMediaType.EBOOK,
    )
}
