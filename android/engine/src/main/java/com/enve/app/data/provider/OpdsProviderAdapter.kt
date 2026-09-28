package com.enve.app.data.provider

import com.enve.app.data.opds.OpdsProgressionPushResult
import com.enve.app.data.opds.OpdsProgressionService
import com.enve.app.data.opds.OpdsProgressionSupersededException
import com.enve.app.data.repository.OpdsRepository
import com.enve.app.data.repository.resolveOpdsAcquisitionUrl
import com.enve.app.data.repository.toOpdsBook
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.sync.SyncCapability
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.util.runSuspendCatching
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OpdsProviderAdapter @Inject constructor(
    private val repository: OpdsRepository,
    private val bookCache: BookCacheDao,
    private val connectionRegistry: ConnectionRegistry,
    private val prefs: PreferencesManager,
    private val progression: OpdsProgressionService,
) : ProviderAdapter {
    override val source: BookSource = BookSource.OPDS

    override val syncCapability: SyncCapability = SyncCapability.READ_WRITE

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
            result.items.map { it.toOpdsBook() }
        }

    override suspend fun getContinueListening(): Result<List<Book>> = Result.success(emptyList())

    override suspend fun getContinueReading(): Result<List<Book>> = Result.success(emptyList())

    override suspend fun getRecentlyAdded(): Result<List<Book>> =
        getBooks(libraryId = "root", page = 0, size = 50, sort = "addedOn", dir = "desc")

    override suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = runCatching {
        if (book.mediaType != AppMediaType.AUDIOBOOK) return@runCatching emptyList()
        val contentUrl = resolveAcquisitionUrl(book.id) ?: return@runCatching emptyList()
        listOf(
            AudioTrack(
                index = 0,
                fileName = book.title,
                title = book.title,
                durationMs = book.duration * 1000L,
                contentUrl = contentUrl,
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

    override suspend fun getEbookDownloadUrl(bookId: String): String? = resolveAcquisitionUrl(bookId)

    override suspend fun fetchAudiobookProgress(book: Book): Result<SyncSnapshot?> =
        runSuspendCatching { progression.fetch(book) }

    override suspend fun fetchEbookProgress(book: Book): Result<SyncSnapshot?> =
        runSuspendCatching { progression.fetch(book) }

    override suspend fun syncAudiobookProgress(
        book: Book,
        currentTimeSec: Long,
        progressFraction: Float,
    ): Result<Unit> = runSuspendCatching {
        progression.push(
            book = book,
            percentage = progressFraction,
            currentTimeSec = currentTimeSec,
            locatorJson = book.epubLocator,
            page = null,
        ).orThrow()
    }

    override suspend fun syncEbookProgress(
        bookId: String,
        percentage: Float,
        locator: String?,
        page: Int?,
        pageCount: Int?,
    ): Result<Unit> = runSuspendCatching {
        val book = bookCache.getByIdAndConnection(bookId, scopedConnectionId())?.toBook()
            ?: return@runSuspendCatching
        progression.push(
            book = book,
            percentage = percentage,
            currentTimeSec = null,
            locatorJson = locator ?: book.epubLocator,
            page = page,
        ).orThrow()
    }

    override suspend fun validateConnection(): Result<Boolean> =
        repository.getRootPage(scopedConnectionId()).map { true }

    override fun invalidateCaches() {
        repository.invalidateCaches()
    }

    private fun OpdsProgressionPushResult.orThrow() {
        when (this) {
            OpdsProgressionPushResult.Superseded -> throw OpdsProgressionSupersededException()
            is OpdsProgressionPushResult.Failed ->
                throw IllegalStateException("OPDS progression rejected the update ($reason)")

            OpdsProgressionPushResult.Written,
            OpdsProgressionPushResult.Skipped -> Unit
        }
    }

    private suspend fun resolveAcquisitionUrl(bookId: String): String? {
        val connectionId = scopedConnectionId()
        return resolveOpdsAcquisitionUrl(
            cached = bookCache.getByIdAndConnection(bookId, connectionId),
            bookId = bookId,
            serverUrl = repository.getRootCatalogUrl(connectionId),
        )
    }

    private fun scopedConnectionId(): String {
        val scopedId = ConnectionScope.getConnectionId() ?: prefs.getActiveConnectionIdSync()
        if (!scopedId.isNullOrBlank()) return scopedId
        return connectionRegistry.getConnectionsSync().firstOrNull { it.source == BookSource.OPDS }?.id
            ?: error("No OPDS connection selected")
    }
}
