package com.enve.local

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderMetadataUpdate
import com.enve.core.data.remote.ConnectionScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class LocalProviderAdapter @Inject constructor(
    private val localRepository: LocalLibraryRepository,
    private val prefs: PreferencesManager,
    private val connectionRegistry: ConnectionRegistry,
) : ProviderAdapter {
    override val source: BookSource = BookSource.LOCAL
    override val supportsMetadataUpdate: Boolean = true

    override suspend fun getLibraries(): Result<List<Library>> = Result.success(listOf(
        Library(id = "local-main", name = "Local Files", bookCount = 0)
    ))

    override suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String
    ): Result<List<Book>> = withContext(Dispatchers.IO) {
        val uriString = scopedUri() ?: return@withContext Result.failure(Exception("No local library URI found"))
        val sourceId = ConnectionScope.getConnectionId() ?: "local-main"
        val books = localRepository.scanDirectory(uriString, sourceId)
        Result.success(books)
    }

    override suspend fun getContinueListening(): Result<List<Book>> = Result.success(emptyList())
    override suspend fun getContinueReading(): Result<List<Book>> = Result.success(emptyList())
    override suspend fun getRecentlyAdded(): Result<List<Book>> = Result.success(emptyList())

    override suspend fun getEbookDownloadUrl(bookId: String): String? = bookId

    override suspend fun updateBookMetadata(
        book: Book,
        metadata: ProviderMetadataUpdate,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        val uriString = scopedUri()
            ?: return@withContext Result.failure(Exception("No local library URI found"))
        localRepository.updateBookMetadata(uriString, book, metadata)
    }

    override suspend fun deleteBook(book: Book): Result<Unit> = withContext(Dispatchers.IO) {
        val uriString = scopedUri()
            ?: return@withContext Result.failure(Exception("No local library URI found"))
        localRepository.deleteBook(uriString, book)
    }

    override suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = runCatching {
        if (book.mediaType != AppMediaType.AUDIOBOOK) return@runCatching emptyList()
        val uriString = scopedUri() ?: error("No local library URI found")
        val sourceId = ConnectionScope.getConnectionId() ?: book.connectionId ?: "local-main"
        localRepository.scanDirectory(uriString, sourceId)
            .firstOrNull { it.id == book.id }
            ?.audioTracks
            ?.takeIf { it.isNotEmpty() }
            ?: listOf(
                AudioTrack(
                    index = 0,
                    fileName = book.title,
                    title = book.title,
                    durationMs = book.duration * 1000L,
                    fileId = book.id,
                    contentUrl = book.id,
                ),
            )
    }

    override fun invalidateCaches() {}

    private fun scopedUri(): String? {
        connectionRegistry.getScopedConnectionSync()?.let { return it.serverUrl }
        return prefs.getServerUrlSync()
    }
}
