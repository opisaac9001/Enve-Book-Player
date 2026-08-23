package com.enve.app.data.repository

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.provider.ActiveSourceProviderAdapter
import com.enve.app.playback.EmbeddedChapterExtractor
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.remote.ConnectionScope
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

@Serializable
data class AggregatedHomeSnapshot(
    val continueListening: List<Book> = emptyList(),
    val continueReading: List<Book> = emptyList(),
    val recentlyAdded: List<Book> = emptyList(),
)

internal fun selectConnectionForBook(
    book: Book,
    connections: List<ProviderConnection>,
): ProviderConnection? = selectConnectionForSource(book.source, book.connectionId, connections)

internal fun selectConnectionForSource(
    source: BookSource,
    connectionId: String?,
    connections: List<ProviderConnection>,
): ProviderConnection? = connectionId
    ?.let { id -> connections.firstOrNull { it.id == id && it.source == source } }
    ?: connections.firstOrNull { it.source == source }

@Singleton
class AggregatorRepository @Inject constructor(
    private val activeSourceAdapter: ActiveSourceProviderAdapter,
    private val bookCacheDao: com.enve.core.data.local.BookCacheDao,

    private val providerAdapters: Set<@JvmSuppressWildcards ProviderAdapter>,
    private val komgaRepository: com.enve.komga.KomgaRepository,
    private val storytellerRepository: com.enve.storyteller.StorytellerRepository,
    private val connectionRegistry: ConnectionRegistry,
    private val legacyRepository: GrimmoryRepository,
    private val offlineDownloadManager: OfflineDownloadManager,
    private val comicOfflineService: dagger.Lazy<com.enve.app.data.offline.ComicOfflineService>,
    private val embeddedChapterExtractor: EmbeddedChapterExtractor,
    private val prefs: com.enve.core.data.local.PreferencesManager,
    private val vault: com.enve.core.auth.CredentialVault,
    @ApplicationContext private val context: android.content.Context,
) {
    private val jsonSerializer = Json { ignoreUnknownKeys = true }

    @Serializable
    private data class HomeSnapshotCachePayload(
        val connectionIds: List<String> = emptyList(),
        val savedAt: Long,
        val snapshot: AggregatedHomeSnapshot = AggregatedHomeSnapshot(),
    )

    private fun cacheFileForHome(): java.io.File {
        val cacheDir = java.io.File(context.cacheDir, "book-index-cache").also { it.mkdirs() }
        return java.io.File(cacheDir, "aggregated_home_snapshot.json")
    }

    suspend fun clearHomeSnapshotCache() = withContext(Dispatchers.IO) {
        runCatching { cacheFileForHome().delete() }
    }

    private suspend fun saveHomeToDisk(connectionIds: List<String>, snapshot: AggregatedHomeSnapshot) = withContext(Dispatchers.IO) {
        runCatching {
            val payload = HomeSnapshotCachePayload(
                connectionIds = connectionIds.sorted(),
                savedAt = System.currentTimeMillis(),
                snapshot = snapshot,
            )
            cacheFileForHome().writeText(jsonSerializer.encodeToString(payload))
            android.util.Log.d("AggregatorRepository", "Saved home snapshot to cache for ${connectionIds.size} connections")
        }
    }

    private fun getAdapterForSource(source: BookSource): ProviderAdapter {
        return providerAdapters.find { it.source == source } ?: object : ProviderAdapter {
            override val source: BookSource = source
            override suspend fun getLibraries(): Result<List<Library>> = legacyRepository.getLibrariesForSource(source)
            override suspend fun getBooks(libraryId: String?, page: Int, size: Int, sort: String, dir: String): Result<List<Book>> =
                legacyRepository.getBooksForSource(source, libraryId, page, size, sort, dir)
            override suspend fun getContinueListening(): Result<List<Book>> = legacyRepository.getContinueListeningForSource(source)
            override suspend fun getContinueReading(): Result<List<Book>> = legacyRepository.getContinueReadingForSource(source)
            override suspend fun getRecentlyAdded(): Result<List<Book>> = legacyRepository.getRecentlyAddedForSource(source)
            override suspend fun getEbookDownloadUrl(bookId: String): String? = legacyRepository.getEbookDownloadUrl(bookId)
            override fun invalidateCaches() {
                legacyRepository.invalidateListCaches()
            }
        }
    }

    suspend fun enabledSources(): Set<BookSource> {
        return connectionRegistry.connections.first()
            .filter { it.enabled }
            .map { it.source }
            .toSet()
    }

    private data class ParsedLibraryId(
        val connectionId: String?,
        val source: BookSource?,
        val rawId: String?,
    )

    private fun compositeLibraryId(connectionId: String, rawId: String): String = "$connectionId::$rawId"

    private fun parseCompositeLibraryId(composite: String?): ParsedLibraryId {
        if (composite.isNullOrBlank()) return ParsedLibraryId(null, null, null)
        val parts = composite.split("::", limit = 2)
        if (parts.size != 2) return ParsedLibraryId(null, null, composite)
        val legacySource = runCatching { BookSource.valueOf(parts[0]) }.getOrNull()
        return if (legacySource != null) {
            ParsedLibraryId(connectionId = null, source = legacySource, rawId = parts[1])
        } else {
            ParsedLibraryId(connectionId = parts[0], source = null, rawId = parts[1])
        }
    }

    private fun bookIdentity(book: Book): String = "${book.source.name}:${book.id.ifBlank { book.title }}"

    private fun Book.withConnection(connection: ProviderConnection): Book {
        val rawLibraryId = libraryId
        return copy(
            source = connection.source,
            connectionId = connection.id,
            libraryId = rawLibraryId?.takeIf { it.isNotBlank() }?.let { compositeLibraryId(connection.id, it) },
        )
    }

    private suspend fun connectionForBook(book: Book): ProviderConnection? {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        return selectConnectionForBook(book, connections)
    }

    private val connectionMutex = Mutex()

    private suspend fun <T> withConnectionContext(connection: com.enve.core.data.model.ProviderConnection, block: suspend () -> Result<T>): Result<T> {
        connectionMutex.withLock {
            applyConnection(connection)
        }
        return kotlinx.coroutines.withContext(ConnectionScope.asContextElement(connection.id)) {
            block()
        }
    }

    private fun applyConnection(connection: com.enve.core.data.model.ProviderConnection) {
        prefs.setCachedConnectionContext(
            source = connection.source,
            serverUrl = connection.serverUrl,
            username = connection.username,
            connectionId = connection.id,
            accessToken = null,
            refreshToken = null,
            password = null,
        )
    }

    suspend fun getLibraries(): Result<List<Library>> {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        if (connections.isEmpty()) return activeSourceAdapter.getLibraries()

        val results = coroutineScope {
            connections.map { connection ->
                async(Dispatchers.IO) {
                    withConnectionContext(connection) {
                        val adapter = getAdapterForSource(connection.source)
                        adapter.getLibraries()
                    }.let { result ->
                        connection to result
                    }
                }
            }.awaitAll()
        }

        val merged = mutableListOf<Library>()
        var lastError: Throwable? = null
        for ((connection, result) in results) {
            result.onSuccess { libs ->
                merged += libs.map {
                    it.copy(
                        id = compositeLibraryId(connection.id, it.id),
                        source = connection.source,
                        connectionId = connection.id,
                    )
                }
            }.onFailure { err ->
                lastError = err
                android.util.Log.w(
                    "AggregatorRepository",
                    "getLibraries failed for connection=${connection.id} source=${connection.source.name}: ${err.javaClass.simpleName}: ${err.message}",
                )
            }
        }

        if (merged.isEmpty() && lastError != null) {
            return Result.failure(lastError)
        }

        return Result.success(merged.distinctBy { it.id })
    }

    suspend fun getBookDetail(book: Book): Result<Book?> {
        val connection = connectionRegistry.connections.first().find { it.id == book.connectionId }
            ?: return Result.success(null)
        return withConnectionContext(connection) {
            when (book.source) {
                BookSource.GRIMMORY -> legacyRepository.getBookDetail(book.id).map { it as Book? }
                else -> Result.success<Book?>(null)
            }
        }
    }

    suspend fun getBooks(
        libraryId: String? = null,
        page: Int = 0,
        size: Int = 50,
        sort: String = "addedOn",
        dir: String = "desc",
    ): Result<List<Book>> {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        if (connections.isEmpty()) {
            return activeSourceAdapter.getBooks(
                libraryId = libraryId,
                page = page,
                size = size,
                sort = sort,
                dir = dir,
            )
        }

        val parsedLibraryId = parseCompositeLibraryId(libraryId)
        val targetConnections = when {
            parsedLibraryId.connectionId != null -> connections.filter { it.id == parsedLibraryId.connectionId }
            parsedLibraryId.source != null -> connections.filter { it.source == parsedLibraryId.source }
            else -> connections
        }

        val allBooks = mutableListOf<Book>()
        var lastError: Throwable? = null

        for (connection in targetConnections) {
            withConnectionContext(connection) {
                val adapter = getAdapterForSource(connection.source)
                val adapterLibraryId = when {
                    parsedLibraryId.connectionId == connection.id -> parsedLibraryId.rawId
                    parsedLibraryId.source == adapter.source -> parsedLibraryId.rawId
                    else -> null
                }
                adapter.getBooks(
                    libraryId = adapterLibraryId,
                    page = page,
                    size = size,
                    sort = sort,
                    dir = dir,
                ).onSuccess { books ->
                    allBooks += books.map { book -> book.withConnection(connection) }
                }.onFailure { err ->
                    lastError = err
                    android.util.Log.w("AggregatorRepository", "getBooks failed for ${connection.source.name}: ${err.message}")
                }
                Result.success(Unit)
            }
        }

        if (allBooks.isEmpty() && lastError != null) {
            return Result.failure(lastError)
        }

        val unique = allBooks.asSequence()
            .distinctBy { bookIdentity(it) }
            .sortedByDescending { it.addedOn }
            .map { withOfflineDownloadState(it) }
            .toList()

        return Result.success(unique)
    }

    suspend fun getHomeSnapshot(): Result<AggregatedHomeSnapshot> {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        val connectionIds = connections.map { it.id }.sorted()

        if (connections.isEmpty()) {
            val listening = activeSourceAdapter.getContinueListening().getOrElse { return Result.failure(it) }
            val reading = activeSourceAdapter.getContinueReading().getOrElse { return Result.failure(it) }
            val recent = activeSourceAdapter.getRecentlyAdded().getOrElse { return Result.failure(it) }
            val snapshot = AggregatedHomeSnapshot(
                continueListening = listening,
                continueReading = reading,
                recentlyAdded = recent,
            )
            saveHomeToDisk(emptyList(), snapshot)
            return Result.success(snapshot)
        }

        val allListening = mutableListOf<Book>()
        val allReading = mutableListOf<Book>()
        val allRecent = mutableListOf<Book>()

        for (conn in connections) {
            withConnectionContext(conn) {
                val adapter = getAdapterForSource(conn.source)
                val listeningRaw = adapter.getContinueListening().getOrNull().orEmpty().map { it.withConnection(conn) }
                val readingRaw = adapter.getContinueReading().getOrNull().orEmpty().map { it.withConnection(conn) }
                val recentRaw = adapter.getRecentlyAdded().getOrNull().orEmpty().map { it.withConnection(conn) }

                val listening = if (conn.source == BookSource.GRIMMORY) {
                    legacyRepository.hydrateHomeShelfBooks(listeningRaw)
                } else {
                    listeningRaw
                }
                val reading = if (conn.source == BookSource.GRIMMORY) {
                    legacyRepository.hydrateHomeShelfBooks(readingRaw)
                } else {
                    readingRaw
                }
                val recent = if (conn.source == BookSource.GRIMMORY) {
                    legacyRepository.hydrateHomeShelfBooks(recentRaw)
                } else {
                    recentRaw
                }
                allListening += listening
                allReading += reading
                allRecent += recent
                Result.success(Unit)
            }
        }

        val finalSnapshot = AggregatedHomeSnapshot(
            continueListening = allListening.asSequence()
                .distinctBy { bookIdentity(it) }
                .sortedByDescending { it.lastReadTime }
                .take(20)
                .toList(),
            continueReading = allReading.asSequence()
                .distinctBy { bookIdentity(it) }
                .sortedByDescending { it.lastReadTime }
                .take(20)
                .toList(),
            recentlyAdded = allRecent.asSequence()
                .distinctBy { bookIdentity(it) }
                .sortedByDescending { it.addedOn }
                .take(20)
                .toList(),
        ).let { snapshot ->
            snapshot.copy(
                continueListening = snapshot.continueListening.map { withOfflineDownloadState(it) },
                continueReading = snapshot.continueReading.map { withOfflineDownloadState(it) },
                recentlyAdded = snapshot.recentlyAdded.map { withOfflineDownloadState(it) },
            )
        }

        saveHomeToDisk(connectionIds, finalSnapshot)
        return Result.success(finalSnapshot)
    }

    fun invalidateCaches() {
        legacyRepository.invalidateListCaches()
        providerAdapters.forEach { it.invalidateCaches() }

        runCatching { cacheFileForHome().delete() }
    }

    suspend fun checkAllConnectionsHealth(): Map<String, Boolean> = coroutineScope {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        if (connections.isEmpty()) return@coroutineScope emptyMap()

        connections.map { conn ->
            async(Dispatchers.IO) {
                val ok = runCatching {
                    withConnectionContext(conn) {
                        getAdapterForSource(conn.source).validateConnection()
                    }.getOrNull() ?: false
                }.getOrDefault(false)
                conn.id to ok
            }
        }.awaitAll().toMap()
    }

    suspend fun getEbookDownloadUrl(bookId: String, source: BookSource, connectionId: String? = null): String? {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        val connection = selectConnectionForSource(source, connectionId, connections)

        if (connection != null) {
            return withConnectionContext(connection) {
                Result.success(getAdapterForSource(connection.source).getEbookDownloadUrl(bookId))
            }.getOrNull()
        }

        val adapter = getAdapterForSource(source)
        return adapter.getEbookDownloadUrl(bookId)
    }

    suspend fun getEbookResource(
        bookId: String,
        source: BookSource,
        connectionId: String? = null,
    ): com.enve.core.data.provider.ProviderEbookResource? {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        val connection = selectConnectionForSource(source, connectionId, connections)
        if (connection != null) {
            return withConnectionContext(connection) {
                Result.success(getAdapterForSource(connection.source).getEbookResource(bookId))
            }.getOrNull()
        }
        return getAdapterForSource(source).getEbookResource(bookId)
    }

    suspend fun getComicPageCount(book: Book): Result<Int> {
        if (book.source != BookSource.KOMGA) return Result.failure(UnsupportedOperationException("Page streaming is not supported by ${book.source}"))
        val connection = connectionForBook(book)
        return if (connection != null) {
            withConnectionContext(connection) { komgaRepository.getComicPageCount(book.id) }
        } else {
            komgaRepository.getComicPageCount(book.id)
        }
    }

    suspend fun downloadComicPage(book: Book, pageIndex: Int, destination: java.io.File): Result<Unit> {
        if (book.source != BookSource.KOMGA) return Result.failure(UnsupportedOperationException("Page streaming is not supported by ${book.source}"))
        val connection = connectionForBook(book)
        return if (connection != null) {
            withConnectionContext(connection) { komgaRepository.downloadComicPage(book.id, pageIndex, destination) }
        } else {
            komgaRepository.downloadComicPage(book.id, pageIndex, destination)
        }
    }

    suspend fun getReadaloudDownloadUrl(bookId: String, source: BookSource, connectionId: String? = null): String? {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        val connection = selectConnectionForSource(source, connectionId, connections)

        if (connection != null) {
            return withConnectionContext(connection) {
                Result.success(getAdapterForSource(connection.source).getReadaloudDownloadUrl(bookId))
            }.getOrNull()
        }

        val adapter = getAdapterForSource(source)
        return adapter.getReadaloudDownloadUrl(bookId)
    }

    suspend fun updateBookStatus(book: Book, status: String): Result<Unit> {
        val connection = connectionForBook(book)
        val result = if (connection != null) {
            withConnectionContext(connection) {
                getAdapterForSource(connection.source).updateBookStatus(book.id, status)
            }
        } else {
            getAdapterForSource(book.source).updateBookStatus(book.id, status)
        }
        if (result.isSuccess) {
            val normalizedStatus = status.uppercase()

            runCatching {
                bookCacheDao.updateReadState(
                    bookId = book.id,
                    connectionId = book.connectionId,
                    finished = normalizedStatus == "READ" || normalizedStatus == "COMPLETED",
                    hideFromContinue = normalizedStatus == "ABANDONED",
                    serverReadStatus = normalizedStatus,
                    nowMs = System.currentTimeMillis(),
                )
            }
        }
        return result
    }

    fun supportsPersonalRating(book: Book): Boolean =
        getAdapterForSource(book.source).supportsPersonalRating

    suspend fun updatePersonalRating(book: Book, rating: Int): Result<Unit> {
        val normalizedRating = rating.coerceIn(1, 5)
        val connection = connectionForBook(book)
        val result = if (connection != null) {
            withConnectionContext(connection) {
                getAdapterForSource(connection.source).updatePersonalRating(book.id, normalizedRating)
            }
        } else {
            getAdapterForSource(book.source).updatePersonalRating(book.id, normalizedRating)
        }
        if (result.isSuccess) {
            bookCacheDao.updatePersonalRating(
                bookId = book.id,
                connectionId = book.connectionId,
                rating = normalizedRating.toFloat(),
                nowMs = System.currentTimeMillis(),
            )
        }
        return result
    }

    suspend fun deleteBook(book: Book): Result<Unit> {
        val connection = connectionForBook(book)
        val result = if (connection != null) {
            withConnectionContext(connection) {
                getAdapterForSource(connection.source).deleteBook(book)
            }
        } else {
            getAdapterForSource(book.source).deleteBook(book)
        }
        if (result.isSuccess) {
            bookCacheDao.deleteByCacheKeys(listOf(book.uniqueKey))
        }
        return result
    }

    suspend fun resetBookProgress(book: Book): Result<Unit> {
        val connection = connectionForBook(book)
        val result = if (connection != null) {
            withConnectionContext(connection) {
                getAdapterForSource(connection.source).resetBookProgress(book)
            }
        } else {
            getAdapterForSource(book.source).resetBookProgress(book)
        }
        if (result.isSuccess) {
            runCatching {
                bookCacheDao.updateUnifiedProgress(
                    bookId = book.id,
                    connectionId = book.connectionId,
                    progress = 0f,
                    currentTimeSec = 0L,
                    locatorJson = null,
                    nowMs = System.currentTimeMillis(),
                )
                bookCacheDao.updateFinishedStatus(
                    bookId = book.id,
                    connectionId = book.connectionId,
                    finished = false,
                    nowMs = System.currentTimeMillis(),
                )
            }
        }
        return result
    }

    suspend fun markSeriesRead(book: Book, seriesId: String): Result<Unit> {
        val connection = connectionForBook(book)
        if (connection != null) {
            return withConnectionContext(connection) {
                getAdapterForSource(connection.source).markSeriesRead(seriesId)
            }
        }
        return getAdapterForSource(book.source).markSeriesRead(seriesId)
    }

    suspend fun markSeriesUnread(book: Book, seriesId: String): Result<Unit> {
        val connection = connectionForBook(book)
        if (connection != null) {
            return withConnectionContext(connection) {
                getAdapterForSource(connection.source).markSeriesUnread(seriesId)
            }
        }
        return getAdapterForSource(book.source).markSeriesUnread(seriesId)
    }

    data class KomgaListEntry(
        val connectionId: String,
        val id: String,
        val name: String,
        val itemCount: Int,
        val kind: Kind,
    ) {
        enum class Kind { READ_LIST, COLLECTION }
    }

    suspend fun getKomgaReadLists(): List<KomgaListEntry> {
        val connections = connectionRegistry.connections.first()
            .filter { it.enabled && it.source == BookSource.KOMGA }
        val out = mutableListOf<KomgaListEntry>()
        for (connection in connections) {
            withConnectionContext(connection) {
                val lists = komgaRepository.getReadLists().getOrDefault(emptyList())
                for (rl in lists) {
                    out += KomgaListEntry(
                        connectionId = connection.id,
                        id = rl.id,
                        name = rl.name,
                        itemCount = rl.bookIds?.size ?: 0,
                        kind = KomgaListEntry.Kind.READ_LIST,
                    )
                }
                Result.success(Unit)
            }
        }
        return out
    }

    suspend fun getKomgaCollections(): List<KomgaListEntry> {
        val connections = connectionRegistry.connections.first()
            .filter { it.enabled && it.source == BookSource.KOMGA }
        val out = mutableListOf<KomgaListEntry>()
        for (connection in connections) {
            withConnectionContext(connection) {
                val cs = komgaRepository.getCollections().getOrDefault(emptyList())
                for (c in cs) {
                    out += KomgaListEntry(
                        connectionId = connection.id,
                        id = c.id,
                        name = c.name,
                        itemCount = c.seriesIds?.size ?: 0,
                        kind = KomgaListEntry.Kind.COLLECTION,
                    )
                }
                Result.success(Unit)
            }
        }
        return out
    }

    suspend fun getKomgaReadListBooks(connectionId: String, readListId: String): List<Book> {
        val connection = connectionRegistry.connections.first().find { it.id == connectionId } ?: return emptyList()
        return withConnectionContext(connection) {
            Result.success(komgaRepository.getReadListBooks(readListId).getOrDefault(emptyList()))
        }.getOrDefault(emptyList())
    }

    suspend fun getKomgaCollectionBooks(connectionId: String, collectionId: String): List<Book> {
        val connection = connectionRegistry.connections.first().find { it.id == connectionId } ?: return emptyList()
        return withConnectionContext(connection) {
            val seriesList = komgaRepository.getCollectionSeries(collectionId).getOrDefault(emptyList())
            val books = coroutineScope {
                seriesList
                    .map { series -> async { komgaRepository.getSeriesBooks(series.id).getOrDefault(emptyList()) } }
                    .awaitAll()
                    .flatten()
            }
            Result.success(books)
        }.getOrDefault(emptyList())
    }

    data class StorytellerCollectionEntry(
        val connectionId: String,
        val id: String,
        val name: String,
        val bookCount: Int,
    )

    suspend fun getStorytellerCollections(): List<StorytellerCollectionEntry> {
        val connections = connectionRegistry.connections.first()
            .filter { it.enabled && it.source == BookSource.STORYTELLER }
        val out = mutableListOf<StorytellerCollectionEntry>()
        for (connection in connections) {
            withConnectionContext(connection) {
                val cs = storytellerRepository.getCollections().getOrDefault(emptyList())
                for (c in cs) {
                    out += StorytellerCollectionEntry(
                        connectionId = connection.id,
                        id = c.id,
                        name = c.name,
                        bookCount = c.bookCount,
                    )
                }
                Result.success(Unit)
            }
        }
        return out
    }

    suspend fun getStorytellerCollectionBooks(connectionId: String, collectionId: String): List<Book> {
        val connection = connectionRegistry.connections.first().find { it.id == connectionId } ?: return emptyList()
        return withConnectionContext(connection) {
            Result.success(storytellerRepository.getCollectionBooks(collectionId).getOrDefault(emptyList()))
        }.getOrDefault(emptyList())
    }

    suspend fun getAudioTracks(book: Book): Result<List<com.enve.core.data.model.AudioTrack>> {
        val connection = connectionForBook(book)
        if (connection != null) {
            return withConnectionContext(connection) {
                getAdapterForSource(connection.source).getAudioTracks(book)
            }
        }
        val adapter = getAdapterForSource(book.source)
        return adapter.getAudioTracks(book)
    }

    suspend fun startPlaybackSession(book: Book): Result<com.enve.core.data.provider.ProviderPlaybackSession> {
        val connection = connectionForBook(book)
        if (connection != null) {
            return withConnectionContext(connection) {
                getAdapterForSource(connection.source).startPlaybackSession(book)
            }
        }
        val adapter = getAdapterForSource(book.source)
        return adapter.startPlaybackSession(book)
    }

    suspend fun fetchChapters(book: Book): Result<List<com.enve.core.data.model.Chapter>> {
        val connection = connectionForBook(book)
        if (connection != null) {
            return withConnectionContext(connection) {
                getAdapterForSource(connection.source).fetchChapters(book)
            }
        }
        val adapter = getAdapterForSource(book.source)
        return adapter.fetchChapters(book)
    }

    suspend fun fetchEmbeddedChapters(book: Book): Result<List<com.enve.core.data.model.Chapter>> {
        val connection = connectionForBook(book)
        if (connection != null) {
            return withConnectionContext(connection) {
                fetchEmbeddedChapters(getAdapterForSource(connection.source), book)
            }
        }
        return fetchEmbeddedChapters(getAdapterForSource(book.source), book)
    }

    private suspend fun fetchEmbeddedChapters(
        adapter: ProviderAdapter,
        book: Book,
    ): Result<List<com.enve.core.data.model.Chapter>> = try {
        val tracks = adapter.getAudioTracks(book).getOrThrow()
        Result.success(embeddedChapterExtractor.fetchEmbeddedChapters(tracks, book.duration))
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Result.failure(e)
    }

    suspend fun syncAudiobookProgress(
        book: Book,
        currentTimeSec: Long,
        progressFraction: Float,
    ): Result<Unit> {
        val connection = connectionForBook(book)
        val result = if (connection != null) {
            withConnectionContext(connection) {
                getAdapterForSource(connection.source).syncAudiobookProgress(book, currentTimeSec, progressFraction)
            }
        } else {
            getAdapterForSource(book.source).syncAudiobookProgress(book, currentTimeSec, progressFraction)
        }

        if (result.isSuccess) {
            runCatching {
                bookCacheDao.updateUnifiedProgress(
                    bookId = book.id,
                    connectionId = book.connectionId,
                    progress = progressFraction.coerceIn(0f, 1f),
                    currentTimeSec = currentTimeSec,
                    locatorJson = null,
                    nowMs = System.currentTimeMillis(),
                )
            }
        }
        return result
    }

    suspend fun fetchAudiobookProgress(book: Book): Result<com.enve.core.data.sync.SyncSnapshot?> {
        val connection = connectionForBook(book)
        return if (connection != null) {
            withConnectionContext(connection) {
                getAdapterForSource(connection.source).fetchAudiobookProgress(book)
            }
        } else {
            getAdapterForSource(book.source).fetchAudiobookProgress(book)
        }
    }

    suspend fun fetchEbookProgress(book: com.enve.core.data.model.Book): Result<com.enve.core.data.sync.SyncSnapshot?> {
        val connection = connectionForBook(book)
        return if (connection != null) {
            withConnectionContext(connection) {
                getAdapterForSource(connection.source).fetchEbookProgress(book)
            }
        } else {
            getAdapterForSource(book.source).fetchEbookProgress(book)
        }
    }

    suspend fun getComicReadingDirection(book: Book): Result<String?> {
        val connection = connectionForBook(book)
        return if (connection != null) {
            withConnectionContext(connection) {
                getAdapterForSource(connection.source).getComicReadingDirection(book)
            }
        } else {
            getAdapterForSource(book.source).getComicReadingDirection(book)
        }
    }

    suspend fun syncEbookProgress(
        bookId: String,
        source: BookSource,
        percentage: Float,
        locator: String?,
        page: Int? = null,
        pageCount: Int? = null,
        connectionId: String? = null,
    ): Result<Unit> {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        val connection = selectConnectionForSource(source, connectionId, connections)

        runCatching {
            bookCacheDao.updateUnifiedProgress(
                bookId = bookId,
                connectionId = connection?.id,
                progress = percentage.coerceIn(0f, 1f),
                currentTimeSec = -1L,
                locatorJson = locator,
                nowMs = System.currentTimeMillis(),
            )
        }

        val result = if (connection != null) {
            withConnectionContext(connection) {
                getAdapterForSource(connection.source).syncEbookProgress(
                    bookId = bookId,
                    percentage = percentage,
                    locator = locator,
                    page = page,
                    pageCount = pageCount,
                )
            }
        } else {
            val adapter = getAdapterForSource(source)
            adapter.syncEbookProgress(
                bookId = bookId,
                percentage = percentage,
                locator = locator,
                page = page,
                pageCount = pageCount,
            )
        }
        return result
    }

    suspend fun getSeries(): Result<List<com.enve.core.data.remote.dto.SeriesSummaryDto>> {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        if (connections.isEmpty()) return activeSourceAdapter.getSeries()

        val results = coroutineScope {
            connections.map { connection ->
                async(Dispatchers.IO) {
                    withConnectionContext(connection) {
                        getAdapterForSource(connection.source).getSeries()
                    }.let { connection to it }
                }
            }.awaitAll()
        }
        val merged = mutableListOf<com.enve.core.data.remote.dto.SeriesSummaryDto>()
        for ((connection, result) in results) {
            result.onSuccess { merged += it }
                .onFailure { err ->
                    android.util.Log.w(
                        "AggregatorRepository",
                        "getSeries failed for connection=${connection.id} source=${connection.source.name}: ${err.message}",
                    )
                }
        }
        return Result.success(merged.distinctBy { it.name })
    }

    suspend fun getAuthors(): Result<List<com.enve.core.data.remote.dto.AuthorSummaryDto>> {
        val connections = connectionRegistry.connections.first().filter { it.enabled }
        if (connections.isEmpty()) return activeSourceAdapter.getAuthors()

        val results = coroutineScope {
            connections.map { connection ->
                async(Dispatchers.IO) {
                    withConnectionContext(connection) {
                        getAdapterForSource(connection.source).getAuthors()
                    }.let { connection to it }
                }
            }.awaitAll()
        }
        val merged = mutableListOf<com.enve.core.data.remote.dto.AuthorSummaryDto>()
        for ((connection, result) in results) {
            result.onSuccess { merged += it }
                .onFailure { err ->
                    android.util.Log.w(
                        "AggregatorRepository",
                        "getAuthors failed for connection=${connection.id} source=${connection.source.name}: ${err.message}",
                    )
                }
        }
        return Result.success(merged.distinctBy { it.name })
    }

    suspend fun getBrowseSeries(): List<com.enve.core.data.model.BrowseGroup> {
        val rows = bookCacheDao.groupBySeries()
        return rows.map { row ->
            val cover = bookCacheDao.firstCoverForSeries(row.name)
            com.enve.core.data.model.BrowseGroup(
                key = row.name,
                name = row.name,
                count = row.count,
                coverUrl = cover,
            )
        }
    }

    suspend fun getBrowseAuthors(): List<com.enve.core.data.model.BrowseGroup> {
        val rows = bookCacheDao.groupByAuthor()

        val expanded = HashMap<String, Int>()
        val covers = HashMap<String, String?>()
        for (row in rows) {
            val parts = row.name.split(",").map { it.trim() }.filter { it.isNotBlank() }
            for (part in parts) {
                expanded[part] = (expanded[part] ?: 0) + row.count
            }
        }
        return expanded.entries
            .sortedBy { it.key.lowercase() }
            .map { (name, count) ->
                val cover = covers.getOrPut(name) { bookCacheDao.firstCoverForAuthor(name) }
                com.enve.core.data.model.BrowseGroup(
                    key = name,
                    name = name,
                    count = count,
                    coverUrl = cover,
                )
            }
    }

    suspend fun getBrowseNarrators(): List<com.enve.core.data.model.BrowseGroup> {
        val rows = bookCacheDao.groupByNarrator()

        val expanded = HashMap<String, Int>()
        for (row in rows) {
            val parts = row.name.split(",").map { it.trim() }.filter { it.isNotBlank() }
            for (part in parts) {
                expanded[part] = (expanded[part] ?: 0) + row.count
            }
        }
        return expanded.entries
            .sortedBy { it.key.lowercase() }
            .map { (name, count) ->
                com.enve.core.data.model.BrowseGroup(key = name, name = name, count = count)
            }
    }

    suspend fun fetchAudiobookNarrator(book: Book): Result<String?> {
        val adapter = providerAdapters.find { it.source == book.source } ?: return Result.success(null)
        return adapter.fetchAudiobookNarrator(book)
    }

    suspend fun getBooksInSeries(seriesName: String): List<Book> {
        return bookCacheDao.booksWhereSeries(seriesName)
            .map { it.toBook() }
            .map { withOfflineDownloadState(it) }
    }

    suspend fun getBooksByAuthor(authorName: String): List<Book> {

        return bookCacheDao.booksWhereAuthorLike("%$authorName%")
            .map { it.toBook() }
            .filter { book ->
                book.author?.split(",")?.any { it.trim().equals(authorName, ignoreCase = true) } == true
            }
            .map { withOfflineDownloadState(it) }
    }

    suspend fun getBooksByNarrator(narratorName: String): List<Book> {
        return bookCacheDao.booksWhereNarratorLike("%$narratorName%")
            .map { it.toBook() }
            .filter { book ->
                book.narrator?.split(",")?.any { it.trim().equals(narratorName, ignoreCase = true) } == true
            }
            .map { withOfflineDownloadState(it) }
    }

    private fun withOfflineDownloadState(book: Book): Book {

        val downloaded = offlineDownloadManager.isDownloaded(book.id) ||
            comicOfflineService.get().isDownloaded(book.id)
        return if (downloaded && !book.isDownloaded) book.copy(isDownloaded = true) else book
    }
}
