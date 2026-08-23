package com.enve.app.data.repository

import android.util.Log
import com.enve.app.data.links.BookLinkRepository
import com.enve.app.data.metadata.MatchedBookMetadataStore
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.BookMetadataOverride
import com.enve.core.data.local.BookMetadataOverrideDao
import com.enve.core.data.local.BrowseGroupRow
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.CachedBookListItem
import com.enve.core.data.local.CachedLibrary
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.LibraryCacheDao
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.local.toBook
import com.enve.core.data.local.toCached
import com.enve.core.data.local.toLibrary
import com.enve.core.data.local.withMetadataOverride
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.encodeToString
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class LibraryCacheRepository @Inject constructor(
    private val dao: BookCacheDao,
    private val libraryDao: LibraryCacheDao,
    private val metadataOverrideDao: BookMetadataOverrideDao,
    private val connectionRegistry: ConnectionRegistry,
    private val aggregator: AggregatorRepository,
    private val matchedMetadataStore: MatchedBookMetadataStore,
    private val bookLinkRepository: BookLinkRepository,
) {
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val refreshMutex = Mutex()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    private val _refreshError = MutableStateFlow<String?>(null)
    val refreshError: StateFlow<String?> = _refreshError.asStateFlow()

    init {
        scope.launch { pruneRemovedConnections() }
    }

    private fun List<Book>.dedupAcrossConnections(): List<Book> =
        distinctBy { book ->
            "${book.source.name}:${book.id.ifBlank { book.title }}"
        }

    private fun List<Book>.applyMetadataOverrides(overrides: List<BookMetadataOverride>): List<Book> {
        if (overrides.isEmpty()) return this
        val byKey = overrides.associateBy { it.bookKey }
        return map { book -> book.withMetadataOverride(byKey[book.uniqueKey]) }
    }

    val inProgressBooks: Flow<List<Book>> =
        combine(dao.observeInProgress(500), metadataOverrideDao.observeAll()) { list, overrides ->
            list.map(CachedBook::toBook).applyMetadataOverrides(overrides)
        }

    fun inProgressBooksExcludingLibraries(excludedLibraryIds: Set<String>): Flow<List<Book>> =
        combine(
            if (excludedLibraryIds.isEmpty()) dao.observeInProgress(500)
            else dao.observeInProgressExcludingLibraries(excludedLibraryIds.toList()),
            metadataOverrideDao.observeAll(),
        ) { list, overrides -> list.map(CachedBook::toBook).applyMetadataOverrides(overrides) }

    val recentlyAddedBooks: Flow<List<Book>> =
        combine(dao.observeRecentlyAdded(40), metadataOverrideDao.observeAll()) { list, overrides ->
            list.map(CachedBook::toBook).applyMetadataOverrides(overrides)
        }

    fun recentlyAddedBooksExcludingLibraries(excludedLibraryIds: Set<String>): Flow<List<Book>> =
        combine(
            if (excludedLibraryIds.isEmpty()) dao.observeRecentlyAdded(40)
            else dao.observeRecentlyAddedExcludingLibraries(excludedLibraryIds.toList()),
            metadataOverrideDao.observeAll(),
        ) { list, overrides -> list.map(CachedBook::toBook).applyMetadataOverrides(overrides) }

    val downloadedBooks: Flow<List<Book>> =
        combine(dao.observeDownloaded(40), metadataOverrideDao.observeAll()) { list, overrides ->
            list.map(CachedBook::toBook).applyMetadataOverrides(overrides)
        }

    fun downloadedBooksExcludingLibraries(excludedLibraryIds: Set<String>): Flow<List<Book>> =
        combine(
            if (excludedLibraryIds.isEmpty()) dao.observeDownloaded(40)
            else dao.observeDownloadedExcludingLibraries(excludedLibraryIds.toList()),
            metadataOverrideDao.observeAll(),
        ) { list, overrides -> list.map(CachedBook::toBook).applyMetadataOverrides(overrides) }

    val suppressedContinueIdentities: Flow<Set<String>> =
        dao.observeSuppressedContinueIdentities().map { it.toSet() }

    val totalCount: Flow<Int> = dao.observeCount()

    fun totalCountExcludingLibraries(excludedLibraryIds: Set<String>): Flow<Int> =
        if (excludedLibraryIds.isEmpty()) totalCount
        else dao.observeCountExcludingLibraries(excludedLibraryIds.toList())

    val allBooks: Flow<List<Book>> =
        combine(dao.observeAllForList(), metadataOverrideDao.observeAll()) { list, overrides ->
            list.map(CachedBookListItem::toBook).applyMetadataOverrides(overrides).dedupAcrossConnections()
        }

    val rawAllBooks: Flow<List<Book>> =
        combine(dao.observeAllForList(), metadataOverrideDao.observeAll()) { list, overrides ->
            list.map(CachedBookListItem::toBook).applyMetadataOverrides(overrides)
        }

    fun rawAllBooksExcludingLibraries(excludedLibraryIds: Set<String>): Flow<List<Book>> =
        combine(
            if (excludedLibraryIds.isEmpty()) dao.observeAllForList()
            else dao.observeAllForListExcludingLibraries(excludedLibraryIds.toList()),
            metadataOverrideDao.observeAll(),
        ) { list, overrides -> list.map(CachedBookListItem::toBook).applyMetadataOverrides(overrides) }

    val libraries: Flow<List<Library>> =
        libraryDao.observeAll().map { list -> list.map(CachedLibrary::toLibrary) }

    suspend fun saveLocalMetadata(book: Book) {
        val nowMs = System.currentTimeMillis()
        metadataOverrideDao.upsert(
            BookMetadataOverride(
                bookKey = book.uniqueKey,
                title = book.title,
                subtitle = book.subtitle,
                author = book.author,
                narrator = book.narrator,
                description = book.description,
                seriesName = book.seriesName,
                seriesNumber = book.seriesNumber,
                publisher = book.publisher,
                publishedDate = book.publishedDate,
                isbn13 = book.isbn13,
                language = book.language,
                pageCount = book.pageCount,
                updatedAt = nowMs,
            ),
        )
        dao.updateLocalMetadata(
            bookKey = book.uniqueKey,
            title = book.title,
            subtitle = book.subtitle,
            author = book.author,
            narrator = book.narrator,
            coverUrl = book.coverUrl,
            duration = book.duration,
            description = book.description,
            seriesName = book.seriesName,
            seriesNumber = book.seriesNumber,
            publisher = book.publisher,
            publishedDate = book.publishedDate,
            isbn13 = book.isbn13,
            language = book.language,
            pageCount = book.pageCount,
            categoriesJson = runCatching { tagJson.encodeToString(book.categories) }.getOrDefault("[]"),
            nowMs = nowMs,
        )
    }

    suspend fun shouldRefresh(enabledConnectionIds: List<String>, maxAgeMs: Long): Boolean {
        if (dao.count() == 0) return true
        if (enabledConnectionIds.any { dao.countForConnection(it) == 0 }) return true
        if (dao.countInProgressMissingTouchTime() > 0) return true
        val newest = dao.newestCacheWrite() ?: return true
        return System.currentTimeMillis() - newest > maxAgeMs
    }

    fun refreshInBackground() {
        scope.launch { doRefresh() }
    }

    suspend fun refreshNow() {
        aggregator.invalidateCaches()
        doRefresh()
    }

    private val defaultStalenessMs: Long = 6 * 60 * 60 * 1000L

    suspend fun refreshIfStale(maxAgeMs: Long = defaultStalenessMs) {
        val enabled = runCatching {

            emptyList<String>()
        }.getOrDefault(emptyList())
        if (shouldRefresh(enabled, maxAgeMs)) {
            refreshInBackground()
        }
    }

    fun ingestConnectionsInBackground(connectionIds: List<String>) {
        if (connectionIds.isEmpty()) return
        scope.launch { ingestConnections(connectionIds.toSet()) }
    }

    private suspend fun ingestConnections(connectionIds: Set<String>) {
        if (!refreshMutex.tryLock()) return
        _isRefreshing.value = true
        _refreshError.value = null
        try {
            val allLibs = aggregator.getLibraries().getOrElse {
                Log.w(TAG, "ingestConnections getLibraries failed: ${it.message}")
                emptyList()
            }
            val targetLibs = allLibs.filter { it.connectionId in connectionIds }
            if (targetLibs.isNotEmpty()) {
                val nowMs = System.currentTimeMillis()
                libraryDao.upsert(targetLibs.map { it.toCached(nowMs) })
                for (lib in targetLibs) fetchAndUpsert(libraryId = lib.id, connectionId = lib.connectionId)
            } else {

                fetchAndUpsert(libraryId = null, connectionId = null)
            }
            rebuildAutomaticLinks()
            Log.d(TAG, "ingestConnections complete for ${connectionIds.size} connection(s). Total cached: ${dao.count()}")
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            _refreshError.value = e.message
            Log.e(TAG, "ingestConnections failed", e)
        } finally {
            _isRefreshing.value = false
            refreshMutex.unlock()
        }
    }

    suspend fun invalidateAndRefresh(connectionIds: List<String>? = null) {

        progressCarryover = runCatching {
            dao.getInProgressOnce(limit = 2000).associateBy { it.cacheKey }
        }.getOrDefault(emptyMap())
        if (connectionIds.isNullOrEmpty()) {
            Log.i(TAG, "invalidateAndRefresh: clearing entire cache (was ${dao.count()} rows)")
            dao.clearAll()
            libraryDao.clearAll()
        } else {
            Log.i(TAG, "invalidateAndRefresh: clearing ${connectionIds.size} connections: $connectionIds")
            connectionIds.forEach {
                dao.deleteByConnection(it)
                libraryDao.deleteByConnection(it)
            }
        }
        doRefresh()
    }

    suspend fun clearForConnection(connectionId: String) {
        Log.i(TAG, "clearForConnection: clearing $connectionId (had ${dao.countForConnection(connectionId)} books)")
        dao.deleteByConnection(connectionId)
        libraryDao.deleteByConnection(connectionId)
    }

    private suspend fun pruneRemovedConnections() {
        val activeIds = connectionRegistry.connections.first().mapTo(mutableSetOf()) { it.id }
        val removedIds = dao.getConnectionIds().filterNot(activeIds::contains)
        if (removedIds.isEmpty()) return
        Log.i(TAG, "pruneRemovedConnections: clearing ${removedIds.size} removed connection(s)")
        removedIds.forEach { clearForConnection(it) }
        aggregator.invalidateCaches()
        aggregator.clearHomeSnapshotCache()
    }

    suspend fun seriesGroups(): List<BrowseGroupRow> = dao.groupBySeries()
    suspend fun authorGroups(): List<BrowseGroupRow> = dao.groupByAuthor()
    suspend fun narratorGroups(): List<BrowseGroupRow> = dao.groupByNarrator()

    suspend fun tagGroups(): List<BrowseGroupRow> {
        val counts = HashMap<String, Int>()
        for (json in dao.allCategoriesJson()) {
            val list = runCatching {
                tagJson.decodeFromString<List<String>>(json)
            }.getOrDefault(emptyList())
            for (raw in list) {
                val tag = raw.trim()
                if (tag.isEmpty()) continue
                counts[tag] = (counts[tag] ?: 0) + 1
            }
        }
        return counts.entries
            .map { BrowseGroupRow(it.key, it.value) }
            .sortedBy { it.name.lowercase() }
    }

    suspend fun firstCoverForSeries(name: String): String? = dao.firstCoverForSeries(name)
    suspend fun firstCoverForAuthor(name: String): String? = dao.firstCoverForAuthor(name)

    suspend fun booksInSeries(name: String): List<Book> =
        dao.booksWhereSeries(name).map(CachedBook::toBook)

    suspend fun booksByAuthor(name: String): List<Book> =
        dao.booksWhereAuthorLike("%$name%")
            .map(CachedBook::toBook)

            .filter { book -> book.author?.split(",")?.any { it.trim().equals(name, ignoreCase = true) } == true }

    suspend fun booksByNarrator(name: String): List<Book> =
        dao.booksWhereNarratorLike("%$name%")
            .map(CachedBook::toBook)
            .filter { book -> book.narrator?.split(",")?.any { it.trim().equals(name, ignoreCase = true) } == true }

    suspend fun booksByTag(tag: String): List<Book> {

        val needle = "%\"" + tag.replace("\"", "\\\"") + "\"%"
        return dao.booksWhereTagLike(needle).map(CachedBook::toBook)
    }

    private suspend fun doRefresh() {
        if (!refreshMutex.tryLock()) {
            Log.i(TAG, "doRefresh: another refresh is already running, skipping")
            return
        }
        _isRefreshing.value = true
        _refreshError.value = null
        try {
            Log.i(TAG, "doRefresh: starting full refresh; current cache count=${dao.count()}")
            val libraries: List<Library> = aggregator.getLibraries().getOrElse {
                Log.w(TAG, "doRefresh: aggregator.getLibraries failed: ${it.message}")
                emptyList()
            }
            Log.i(TAG, "doRefresh: aggregator returned ${libraries.size} libraries: ${libraries.joinToString { "${it.name}(connId=${it.connectionId}, id=${it.id})" }}")

            if (libraries.isNotEmpty()) {
                val nowMs = System.currentTimeMillis()
                libraryDao.upsert(libraries.map { it.toCached(nowMs) })
            }

            if (libraries.isEmpty()) {
                Log.i(TAG, "doRefresh: no libraries returned; falling back to fetchAndUpsert(libraryId=null)")
                fetchAndUpsert(libraryId = null, connectionId = null)
            } else {
                for (library in libraries) {
                    val before = dao.count()
                    fetchAndUpsert(libraryId = library.id, connectionId = library.connectionId)
                    val after = dao.count()
                    Log.i(TAG, "doRefresh: library '${library.name}' (id=${library.id}) added ${after - before} new rows; total=${after}")
                }
            }
            rebuildAutomaticLinks()
            Log.i(TAG, "doRefresh: complete. Total cached=${dao.count()}")
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            _refreshError.value = e.message
            Log.e(TAG, "doRefresh: failed", e)
        } finally {
            _isRefreshing.value = false
            progressCarryover = null
            refreshMutex.unlock()
        }

        scope.launch { enrichAudiobookNarrators() }
    }

    suspend fun enrichAudiobookNarratorsNow(): Int = enrichAudiobookNarrators()

    private suspend fun enrichAudiobookNarrators(): Int {
        val candidates = try {
            dao.audiobooksNeedingNarratorEnrichment(limit = 5000)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "enrichAudiobookNarrators: lookup failed: ${e.message}")
            return 0
        }
        if (candidates.isEmpty()) {
            Log.d(TAG, "enrichAudiobookNarrators: nothing to do")
            return 0
        }
        Log.i(TAG, "enrichAudiobookNarrators: starting backfill for ${candidates.size} audiobooks")
        val semaphore = Semaphore(NARRATOR_ENRICH_CONCURRENCY)
        val started = System.currentTimeMillis()
        kotlinx.coroutines.coroutineScope {
            candidates.forEach { ident ->
                launch {
                    semaphore.withPermit {
                        try {
                            val source = runCatching {
                                com.enve.core.data.model.BookSource.valueOf(ident.source)
                            }.getOrNull() ?: return@withPermit
                            val placeholder = Book(
                                id = ident.id,
                                title = "",
                                source = source,
                                mediaType = com.enve.core.data.model.AppMediaType.AUDIOBOOK,
                                connectionId = ident.connectionId,
                            )
                            val result = aggregator.fetchAudiobookNarrator(placeholder)
                            val narrator = result.getOrNull()

                            if (result.isSuccess) {
                                dao.setNarrator(ident.id, ident.connectionId, narrator, System.currentTimeMillis())
                            }
                        } catch (e: kotlinx.coroutines.CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            Log.d(TAG, "enrichAudiobookNarrators: ${ident.source}:${ident.id} failed: ${e.message}")
                        }
                    }
                }
            }
        }
        Log.i(TAG, "enrichAudiobookNarrators: backfill complete in ${System.currentTimeMillis() - started}ms")
        return candidates.size
    }

    private suspend fun rebuildAutomaticLinks() {
        val inserted = try {
            bookLinkRepository.rebuildAutomaticLinks()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "rebuildAutomaticLinks: failed: ${e.message}")
            return
        }
        if (inserted > 0) {
            Log.i(TAG, "rebuildAutomaticLinks: created $inserted ebook/audiobook link(s)")
        }
    }

    private suspend fun fetchAndUpsert(libraryId: String?, connectionId: String?) {
        var page = 0
        val nowMs = System.currentTimeMillis()
        val seenKeys = mutableSetOf<String>()
        val overrides = metadataOverrideDao.getAll().associateBy { it.bookKey }
        while (true) {
            val result = aggregator.getBooks(
                libraryId = libraryId,
                page = page,
                size = PAGE_SIZE,
                sort = "addedOn",
                dir = "desc",
            )
            val books: List<Book> = result.getOrNull() ?: run {
                Log.w(TAG, "fetchAndUpsert: getBooks failed p=$page lib=$libraryId: ${result.exceptionOrNull()?.message}")
                return
            }

            Log.i(TAG, "fetchAndUpsert: lib=$libraryId page=$page got ${books.size} books")
            if (books.isEmpty()) break

            val newBooks = books.filter { book ->
                seenKeys.add("${book.connectionId ?: book.source.name}:${book.id}")
            }
            if (newBooks.isEmpty()) {
                Log.w(TAG, "fetchAndUpsert: stopping for lib=$libraryId at page $page (page returned only already-seen books)")
                break
            }

            newBooks.chunked(BATCH_SIZE).forEach { chunk ->
                val mapped = matchedMetadataStore.applyStoredMetadata(chunk)
                    .map { it.withMetadataOverride(overrides[it.uniqueKey]).toCachedBook(nowMs) }

                val existingByKey = dao.getByCacheKeys(mapped.map { it.cacheKey }).associateBy { it.cacheKey }
                dao.upsert(mapped.map { it.preservingLocalProgress(existingByKey[it.cacheKey] ?: progressCarryover?.get(it.cacheKey)) })
            }
            Log.i(TAG, "fetchAndUpsert: lib=$libraryId page=$page upserted ${newBooks.size} new rows")

            if (books.size != PAGE_SIZE) break
            page++
        }
        if (!connectionId.isNullOrBlank() && !libraryId.isNullOrBlank()) {
            dao.deleteStaleForConnectionLibrary(connectionId, libraryId, nowMs)
        }
    }

    @Volatile private var progressCarryover: Map<String, CachedBook>? = null

    private fun CachedBook.preservingLocalProgress(existing: CachedBook?): CachedBook {
        if (existing == null) return this
        if (source == BookSource.KOMGA.name && mediaType == AppMediaType.EBOOK.name) {
            return this
        }
        val mergedCurrentTime = if (currentTime > 0L) currentTime else existing.currentTime
        val mergedReadProgress = if (readProgress > 0.001f) readProgress else existing.readProgress
        val mergedEpubProgress = epubProgress?.takeIf { it > 0.001f } ?: existing.epubProgress
        val mergedServerReadStatus = serverReadStatus ?: existing.serverReadStatus
        val statusFinished = mergedServerReadStatus in setOf("READ", "COMPLETED", "FINISHED")
        val statusAllowsContinue = source != BookSource.GRIMMORY.name || mergedServerReadStatus == null ||
            mergedServerReadStatus in setOf("READING", "RE_READING", "IN_PROGRESS")
        val audioProgress =
            if (duration > 0 && mergedCurrentTime > 0) mergedCurrentTime.toFloat() / duration else mergedReadProgress
        return copy(
            currentTime = mergedCurrentTime,
            readProgress = mergedReadProgress,
            epubProgress = mergedEpubProgress,
            epubLocator = epubLocator ?: existing.epubLocator,
            serverReadStatus = mergedServerReadStatus,
            isFinished = isFinished || statusFinished,
            lastReadTime = maxOf(lastReadTime, existing.lastReadTime),
            inProgress = !isFinished && !statusFinished && !hideFromContinue && statusAllowsContinue && (
                audioProgress in 0.01f..0.99f ||
                (mergedEpubProgress ?: 0f) in 0.01f..0.99f ||
                mergedCurrentTime > 0L
            ),
        )
    }

    companion object {
        private const val TAG = "LibraryCacheRepository"
        private const val PAGE_SIZE = 500
        private const val BATCH_SIZE = 200
        private const val NARRATOR_ENRICH_CONCURRENCY = 4
        private val tagJson = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
    }
}
