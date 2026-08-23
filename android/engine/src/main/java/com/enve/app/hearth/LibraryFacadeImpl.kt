package com.enve.app.hearth

import com.enve.app.data.offline.ComicOfflineService
import com.enve.app.data.offline.ComicDownloadProgress
import com.enve.app.data.offline.ComicDownloadStatus
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.offline.OfflineDownloadProgress
import com.enve.app.data.offline.OfflineDownloadStatus
import com.enve.app.data.metadata.MatchedBookMetadataStore
import com.enve.app.data.links.BookLinkRepository
import com.enve.app.data.history.HistorySessionStore
import com.enve.app.data.metadata.MetadataCandidateSource
import com.enve.app.data.metadata.MetadataMatchCandidate
import com.enve.app.data.metadata.MetadataSearchRepository
import com.enve.app.data.metadata.ProviderMetadataRepository
import com.enve.app.data.repository.AggregatorRepository
import com.enve.app.data.repository.GrimmoryAppRepository
import com.enve.app.data.repository.LibraryCacheRepository
import com.enve.app.data.sync.RecentlyPlayedSyncService
import com.enve.app.data.sync.ServerStatusSyncTrigger
import com.enve.app.playback.AudioPlaybackManager
import com.enve.app.playback.PlaybackChapterStore
import com.enve.bookorbit.BookOrbitRepository
import com.enve.bookorbit.dto.BookOrbitCollectionDto
import com.enve.bookorbit.dto.BookOrbitCollectionRequest
import com.enve.core.data.local.BookExtras
import com.enve.core.data.local.BookExtrasDao
import com.enve.core.data.local.AudiobookGroupingOverrideStore
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.decodeChapters
import com.enve.core.data.local.encodeChaptersJson
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.isVisibleLibraryBook
import com.enve.core.data.model.visibleLibraryBooks
import com.enve.core.data.model.BrowseGroup
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.toShallowBook
import com.enve.core.data.provider.ProviderMetadataUpdate
import com.enve.core.data.remote.ConnectionScope
import com.enve.engine.library.BookOrbitCollectionEdit
import com.enve.engine.library.BookOrbitCollectionMembership
import com.enve.engine.library.LibraryFacade
import com.enve.engine.library.LibraryDownloadState
import com.enve.engine.library.LibraryDownloadStatus
import com.enve.engine.library.LibraryLinkCandidate
import com.enve.engine.library.LibraryMetadataEdit
import com.enve.engine.library.LibraryMetadataMatch
import com.enve.engine.library.LibraryShelfPage
import com.enve.engine.library.LibraryConnectionOption
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class LibraryFacadeImpl @Inject constructor(
    private val cache: LibraryCacheRepository,
    private val aggregator: AggregatorRepository,
    private val grimmory: GrimmoryAppRepository,
    private val bookOrbit: BookOrbitRepository,
    private val connectionRegistry: ConnectionRegistry,
    private val bookCache: BookCacheDao,
    private val prefs: PreferencesManager,
    private val offlineDownloads: OfflineDownloadManager,
    private val comicOffline: ComicOfflineService,
    private val providerMetadata: ProviderMetadataRepository,
    private val metadataSearch: MetadataSearchRepository,
    private val matchedMetadata: MatchedBookMetadataStore,
    private val bookLinks: BookLinkRepository,
    private val recentlyPlayedSync: RecentlyPlayedSyncService,
    private val chapterStore: PlaybackChapterStore,
    private val audioManager: AudioPlaybackManager,
    private val bookExtras: BookExtrasDao,
    private val history: HistorySessionStore,
    private val groupingOverrides: AudiobookGroupingOverrideStore,
) : LibraryFacade {
    override val historySessions = history.sessions
    override val continueBooks: Flow<List<Book>> = visibleBooks(cache::inProgressBooksExcludingLibraries)
    override val editionLinks: Flow<List<com.enve.engine.library.LibraryEditionLink>> =
        bookLinks.observeLinkedPairs().map { pairs ->
            pairs.map { com.enve.engine.library.LibraryEditionLink(it.ebookKey, it.audiobookKey) }
        }
    override val recentlyAdded: Flow<List<Book>> = visibleBooks(cache::recentlyAddedBooksExcludingLibraries)
    override val downloaded: Flow<List<Book>> = visibleBooks(cache::downloadedBooksExcludingLibraries)
    override val allBooks: Flow<List<Book>> = visibleBooks(cache::rawAllBooksExcludingLibraries)
    override val totalCount: Flow<Int> = prefs.excludedLibraryIds.flatMapLatest(cache::totalCountExcludingLibraries)
    override val libraries: Flow<List<com.enve.core.data.model.Library>> = cache.libraries
    override val isRefreshing: StateFlow<Boolean> = cache.isRefreshing

    private fun visibleBooks(source: (Set<String>) -> Flow<List<Book>>): Flow<List<Book>> =
        prefs.excludedLibraryIds.flatMapLatest { excluded ->
            source(excluded).map { books -> books.visibleLibraryBooks(excluded) }
        }

    private suspend fun visibleBooks(books: List<Book>): List<Book> =
        books.visibleLibraryBooks(prefs.excludedLibraryIds.first())

    private suspend fun Book.takeIfVisible(): Book? =
        takeIf { it.isVisibleLibraryBook(prefs.excludedLibraryIds.first()) }

    override suspend fun browseSeries(): List<BrowseGroup> = aggregator.getBrowseSeries()
    override suspend fun browseAuthors(): List<BrowseGroup> = aggregator.getBrowseAuthors()
    override suspend fun browseShelves(): List<BrowseGroup> = coroutineScope {
        connectionRegistry.connections.first()
            .filter { it.enabled && (it.source == BookSource.GRIMMORY || it.source == BookSource.BOOKORBIT) }
            .map { connection ->
                async {
                    if (connection.source == BookSource.BOOKORBIT) {
                        return@async withContext(ConnectionScope.asContextElement(connection.id)) {
                            val editable = bookOrbit.isCurrentUserAdmin().getOrDefault(false)
                            bookOrbit.getCollections().getOrDefault(emptyList()).map { collection ->
                                collection.toBrowseGroup(connection.id, editable)
                            }
                        }
                    }
                    val regular = grimmory.getShelves(connection.id).getOrDefault(emptyList()).map { shelf ->
                        BrowseGroup(
                            key = shelfKey(connection.id, shelf.id, magic = false),
                            name = shelf.name,
                            count = shelf.bookCount,
                            secondary = "Shelf",
                            sourceConnectionId = connection.id,
                            source = BookSource.GRIMMORY,
                        )
                    }
                    val magic = grimmory.getMagicShelves(connection.id).getOrDefault(emptyList()).map { shelf ->
                        async {
                            val count = grimmory.getMagicShelfBooks(
                                connectionId = connection.id,
                                magicShelfId = shelf.id,
                                size = 1,
                            ).getOrNull()?.totalElements?.toInt() ?: 0
                            BrowseGroup(
                                key = shelfKey(connection.id, shelf.id, magic = true),
                                name = shelf.name,
                                count = count,
                                secondary = "Magic shelf",
                                sourceConnectionId = connection.id,
                                source = BookSource.GRIMMORY,
                            )
                        }
                    }.awaitAll()
                    regular + magic
                }
            }.awaitAll().flatten()
            .distinctBy { it.key }
            .sortedWith(
                compareBy<BrowseGroup> { it.source.name }
                    .thenBy { it.sourceConnectionId.orEmpty() }
                    .thenBy { if (it.source == BookSource.BOOKORBIT) it.displayOrder else Int.MAX_VALUE }
                    .thenBy { it.name.lowercase() },
            )
    }
    override suspend fun booksInSeries(name: String): List<Book> =
        visibleBooks(aggregator.getBooksInSeries(name))
    override suspend fun booksByAuthor(name: String): List<Book> =
        visibleBooks(aggregator.getBooksByAuthor(name))
    override suspend fun booksInShelf(key: String): List<Book> {
        val ref = parseShelfKey(key) ?: return emptyList()
        if (ref.kind == ShelfKind.BOOKORBIT) {
            val books = mutableListOf<Book>()
            var page = 0
            while (true) {
                val result = shelfBooksPage(key, page, 100)
                books += result.items
                if (!result.hasMore) break
                page += 1
            }
            return visibleBooks(books)
        }
        val books = mutableListOf<com.enve.core.data.model.BookSummary>()
        var page = 0
        while (true) {
            val result = if (ref.kind == ShelfKind.GRIMMORY_MAGIC) {
                grimmory.getMagicShelfBooks(ref.connectionId, ref.shelfId, page = page, size = 50)
            } else {
                grimmory.getBooksPage(ref.connectionId, shelfId = ref.shelfId, page = page, size = 50)
            }.getOrNull() ?: break
            books += result.items
            if (!result.hasNext) break
            page += 1
        }
        return visibleBooks(books.distinctBy { it.uniqueKey }.map { it.toShallowBook(grimmory.isDownloaded(it.id)) })
    }

    override suspend fun shelfBooksPage(key: String, page: Int, size: Int, query: String?): LibraryShelfPage {
        val ref = parseShelfKey(key) ?: return LibraryShelfPage(emptyList(), 0, page, false)
        if (ref.kind == ShelfKind.BOOKORBIT) {
            val result = withContext(ConnectionScope.asContextElement(ref.connectionId)) {
                bookOrbit.getCollectionBooks(ref.shelfId.toInt(), page, size, query).getOrNull()
            } ?: return LibraryShelfPage(emptyList(), 0, page, false)
            val hydrated = result.items.map { shallow ->
                bookCache.getByIdAndConnection(shallow.id, ref.connectionId)?.toBook()
                    ?: shallow.copy(connectionId = ref.connectionId)
            }
            return LibraryShelfPage(
                visibleBooks(hydrated),
                result.total,
                result.page,
                (result.page + 1) * result.size < result.total,
            )
        }

        val result = if (ref.kind == ShelfKind.GRIMMORY_MAGIC) {
            grimmory.getMagicShelfBooks(ref.connectionId, ref.shelfId, page = page, size = size).getOrNull()
        } else {
            grimmory.getBooksPage(ref.connectionId, shelfId = ref.shelfId, page = page, size = size).getOrNull()
        } ?: return LibraryShelfPage(emptyList(), 0, page, false)
        return LibraryShelfPage(
            items = visibleBooks(result.items.map { it.toShallowBook(grimmory.isDownloaded(it.id)) }),
            total = result.totalElements.toInt(),
            page = page,
            hasMore = result.hasNext,
        )
    }

    override suspend fun createBookOrbitCollection(connectionId: String, edit: BookOrbitCollectionEdit): BrowseGroup? =
        withContext(ConnectionScope.asContextElement(connectionId)) {
            bookOrbit.createCollection(edit.toRequest()).getOrNull()?.toBrowseGroup(connectionId, editable = true)
        }

    override suspend fun updateBookOrbitCollection(collection: BrowseGroup, edit: BookOrbitCollectionEdit): BrowseGroup? {
        val ref = parseShelfKey(collection.key)?.takeIf { it.kind == ShelfKind.BOOKORBIT } ?: return null
        return withContext(ConnectionScope.asContextElement(ref.connectionId)) {
            bookOrbit.updateCollection(ref.shelfId.toInt(), edit.toRequest()).getOrNull()?.toBrowseGroup(ref.connectionId, editable = true)
        }
    }

    override suspend fun deleteBookOrbitCollection(collection: BrowseGroup): Boolean {
        val ref = parseShelfKey(collection.key)?.takeIf { it.kind == ShelfKind.BOOKORBIT } ?: return false
        return withContext(ConnectionScope.asContextElement(ref.connectionId)) {
            bookOrbit.deleteCollection(ref.shelfId.toInt()).isSuccess
        }
    }

    override suspend fun addBookToBookOrbitCollection(collection: BrowseGroup, book: Book): Boolean =
        mutateBookOrbitCollectionMembership(collection, listOf(book), add = true)

    override suspend fun addBooksToBookOrbitCollection(collection: BrowseGroup, books: List<Book>): Boolean =
        mutateBookOrbitCollectionMembership(collection, books, add = true)

    override suspend fun removeBookFromBookOrbitCollection(collection: BrowseGroup, book: Book): Boolean =
        mutateBookOrbitCollectionMembership(collection, listOf(book), add = false)

    private suspend fun mutateBookOrbitCollectionMembership(collection: BrowseGroup, books: List<Book>, add: Boolean): Boolean {
        val ref = parseShelfKey(collection.key)?.takeIf { it.kind == ShelfKind.BOOKORBIT } ?: return false
        val bookIds = BookOrbitCollectionPolicy.bookIds(ref.connectionId, books) ?: return false
        return withContext(ConnectionScope.asContextElement(ref.connectionId)) {
            val result = if (add) bookOrbit.addCollectionBooks(ref.shelfId.toInt(), bookIds)
            else bookOrbit.removeCollectionBooks(ref.shelfId.toInt(), bookIds)
            result.isSuccess
        }
    }

    override suspend fun reorderBookOrbitCollections(connectionId: String, orderedKeys: List<String>): Boolean {
        val ids = orderedKeys.mapNotNull { key ->
            parseShelfKey(key)?.takeIf { it.kind == ShelfKind.BOOKORBIT && it.connectionId == connectionId }?.shelfId?.toInt()
        }
        if (ids.isEmpty()) return false
        return withContext(ConnectionScope.asContextElement(connectionId)) { bookOrbit.reorderCollections(ids).isSuccess }
    }

    override suspend fun bookOrbitCollectionsForBook(book: Book): List<BookOrbitCollectionMembership> {
        if (book.source != BookSource.BOOKORBIT) return emptyList()
        val connectionId = book.connectionId ?: return emptyList()
        val bookId = book.id.toIntOrNull() ?: return emptyList()
        return withContext(ConnectionScope.asContextElement(connectionId)) {
            val editable = bookOrbit.isCurrentUserAdmin().getOrDefault(false)
            if (!editable) return@withContext emptyList()
            bookOrbit.getCollections(listOf(bookId)).getOrDefault(emptyList()).map { collection ->
                BookOrbitCollectionMembership(collection.toBrowseGroup(connectionId, editable), collection.memberCount == 1)
            }
        }
    }

    override suspend fun bookOrbitAdminConnections(): List<LibraryConnectionOption> {
        val result = mutableListOf<LibraryConnectionOption>()
        for (connection in connectionRegistry.getConnectionsSync()) {
            if (!connection.enabled || connection.source != BookSource.BOOKORBIT) continue
            val isAdmin = withContext(ConnectionScope.asContextElement(connection.id)) {
                bookOrbit.isCurrentUserAdmin().getOrDefault(false)
            }
            if (isAdmin) {
                result += LibraryConnectionOption(connection.id, connection.name.ifBlank { connection.serverUrl })
            }
        }
        return result
    }
    override suspend fun book(bookId: String): Book? =
        bookCache.getById(bookId)?.toBook()?.withActualDownloadState(
            audioDownloadedIds = offlineDownloads.downloadedBookIds.value,
            comicDownloadedIds = comicOffline.downloadedBookIds.value,
        )?.takeIfVisible()?.let { matchedMetadata.applyStoredMetadata(it) }

    override suspend fun bookDetail(book: Book): Book? =
        aggregator.getBookDetail(book).getOrNull()

    override fun bookFlow(bookId: String): Flow<Book?> = flow {
        combine(
            bookCache.observeById(bookId),
            offlineDownloads.downloadedBookIds,
            comicOffline.downloadedBookIds,
            prefs.excludedLibraryIds,
        ) { cached, audioDownloadedIds, comicDownloadedIds, excludedLibraryIds ->
            cached?.toBook()
                ?.withActualDownloadState(audioDownloadedIds, comicDownloadedIds)
                ?.takeIf { it.isVisibleLibraryBook(excludedLibraryIds) }
        }.collect { book ->
            emit(book?.let { matchedMetadata.applyStoredMetadata(it) })
        }
    }

    override fun bookByKeyFlow(bookKey: String): Flow<Book?> = flow {
        combine(
            bookCache.observeByCacheKey(bookKey),
            offlineDownloads.downloadedBookIds,
            comicOffline.downloadedBookIds,
            prefs.excludedLibraryIds,
        ) { cached, audioDownloadedIds, comicDownloadedIds, excludedLibraryIds ->
            cached?.toBook()
                ?.withActualDownloadState(audioDownloadedIds, comicDownloadedIds)
                ?.takeIf { it.isVisibleLibraryBook(excludedLibraryIds) }
        }.collect { book ->
            emit(book?.let { matchedMetadata.applyStoredMetadata(it) })
        }
    }

    override suspend fun linkedAudiobook(book: Book): Book? =
        bookLinks.linkedAudiobook(book)?.withActualDownloadState(
            audioDownloadedIds = offlineDownloads.downloadedBookIds.value,
            comicDownloadedIds = comicOffline.downloadedBookIds.value,
        )?.takeIfVisible()?.let { matchedMetadata.applyStoredMetadata(it) }

    override suspend fun linkedEbook(book: Book): Book? =
        bookLinks.linkedEbook(book)?.withActualDownloadState(
            audioDownloadedIds = offlineDownloads.downloadedBookIds.value,
            comicDownloadedIds = comicOffline.downloadedBookIds.value,
        )?.takeIfVisible()?.let { matchedMetadata.applyStoredMetadata(it) }

    override suspend fun linkCandidates(book: Book, query: String): List<LibraryLinkCandidate> {
        val excludedLibraryIds = prefs.excludedLibraryIds.first()
        return bookLinks.linkCandidates(book, query)
            .filter { it.book.isVisibleLibraryBook(excludedLibraryIds) }
            .map { candidate ->
            LibraryLinkCandidate(
                book = matchedMetadata.applyStoredMetadata(
                    candidate.book.withActualDownloadState(
                        audioDownloadedIds = offlineDownloads.downloadedBookIds.value,
                        comicDownloadedIds = comicOffline.downloadedBookIds.value,
                    ),
                ),
                confidence = candidate.confidence,
            )
            }
    }

    override suspend fun linkEditions(book: Book, counterpart: Book): Boolean =
        bookLinks.link(book, counterpart)

    override suspend fun unlinkEditions(book: Book): Boolean =
        bookLinks.unlink(book)

    override suspend fun refresh() {
        cache.refreshNow()

        recentlyPlayedSync.sync(ServerStatusSyncTrigger.HOME_PULL_TO_REFRESH)
        prefs.setLastSyncTime(System.currentTimeMillis())
    }

    override suspend fun separateAudiobookChapter(book: Book, chapter: Chapter): Boolean {
        if (book.source != BookSource.LOCAL && book.source != BookSource.SMB) return false
        val tracks = aggregator.getAudioTracks(book).getOrNull() ?: return false
        if (tracks.size <= 1) return false
        val sourceId = book.connectionId ?: return false
        val track = tracks.firstOrNull { it.index == chapter.index } ?: return false
        val fileId = track.fileId ?: track.contentUrl ?: return false

        groupingOverrides.forceStandalone(book.source, sourceId, fileId)
        cache.refreshNow()
        if (cache.refreshError.value == null) return true

        groupingOverrides.removeForcedStandalone(book.source, sourceId, fileId)
        return false
    }

    override val hiddenBookIds: Flow<Set<String>> = prefs.libraryHiddenBookIds

    override suspend fun setFinished(book: Book, finished: Boolean): Boolean =
        aggregator.updateBookStatus(book, if (finished) "READ" else "UNREAD").isSuccess

    override fun supportsPersonalRating(book: Book): Boolean =
        aggregator.supportsPersonalRating(book)

    override suspend fun setPersonalRating(book: Book, rating: Int): Boolean =
        aggregator.updatePersonalRating(book, rating).isSuccess

    override suspend fun setHidden(bookId: String, hidden: Boolean) {
        prefs.updateLibraryHiddenBookIds { if (hidden) it + bookId else it - bookId }
    }

    override fun downloadState(bookId: String): Flow<LibraryDownloadState> =
        combine(
            offlineDownloads.progressByBookId,
            comicOffline.progressByBookId,
            offlineDownloads.downloadedBookIds,
            comicOffline.downloadedBookIds,
        ) { audioProgress, comicProgress, audioDownloadedIds, comicDownloadedIds ->
            audioProgress[bookId]?.toLibraryDownloadState()
                ?: comicProgress[bookId]?.toLibraryDownloadState()
                ?: when {
                    bookId in audioDownloadedIds || bookId in comicDownloadedIds ->
                        LibraryDownloadState(status = LibraryDownloadStatus.COMPLETED, progress = 1f)
                    else -> LibraryDownloadState()
                }
        }

    override suspend fun download(book: Book) {
        if (book.usesOfflineAudioDownload()) {
            offlineDownloads.startAudiobookDownload(book, allowCellular = prefs.downloadOnCellular.first())
        } else {
            if (book.source == BookSource.STORYTELLER && book.readAlongAvailable) {
                offlineDownloads.removeDownload(book.id)
            }
            comicOffline.startDownload(book)
        }
    }

    override suspend fun removeDownload(book: Book) {
        if (book.usesOfflineAudioDownload()) {
            offlineDownloads.removeDownload(book.id)
        } else {
            comicOffline.removeDownload(book.id)
            if (book.source == BookSource.STORYTELLER && book.readAlongAvailable) {
                offlineDownloads.removeDownload(book.id)
            }
        }
    }

    override suspend fun resetProgress(book: Book) {
        aggregator.resetBookProgress(book)
    }

    override suspend fun supportsMetadataEdit(book: Book): Boolean =
        providerMetadata.supportsProviderMetadataUpdate(book)

    override suspend fun updateMetadata(book: Book, metadata: LibraryMetadataEdit): Book? {
        val result = providerMetadata.updateBookMetadata(book, metadata.toProviderUpdate())
        if (result.isFailure) return null
        val updated = book.copy(
            title = metadata.title,
            subtitle = metadata.subtitle,
            author = metadata.author,
            narrator = metadata.narrator,
            description = metadata.description,
            seriesName = metadata.seriesName,
            seriesNumber = metadata.seriesNumber,
            publisher = metadata.publisher,
            publishedDate = metadata.publishedDate,
            isbn13 = metadata.isbn13,
            language = metadata.language,
            pageCount = metadata.pageCount,
            categories = metadata.categories,
        )
        cache.saveLocalMetadata(updated)
        cache.refreshInBackground()
        return book(book.id) ?: updated
    }

    override fun defaultMetadataMatchQuery(book: Book): String =
        metadataSearch.defaultQuery(book)

    override suspend fun searchMetadataMatches(book: Book, query: String): List<LibraryMetadataMatch> =
        metadataSearch.search(book, query).map { it.toLibraryMatch() }

    override suspend fun applyMetadataMatch(book: Book, match: LibraryMetadataMatch): Book? {
        val candidate = metadataSearch.enrichSelectedCandidate(match.toCandidate(book.mediaType))
        val updated = matchedMetadata.saveMatch(book, candidate)
        cache.saveLocalMetadata(updated)
        return updated
    }

    override suspend fun deleteFromLibrary(book: Book): Boolean {
        if (book.source != BookSource.LOCAL) return false
        offlineDownloads.removeDownload(book.id)
        comicOffline.removeDownload(book.id)
        return aggregator.deleteBook(book).isSuccess
    }

    override suspend fun chapters(book: Book, forceEmbedded: Boolean): List<Chapter>? {
        book.chapters.takeIf { it.isNotEmpty() }?.let {
            applyFetchedChapters(book, it)
            return it
        }
        cachedChapters(book)?.let {
            applyFetchedChapters(book, it)
            return it
        }
        val chapters = if (forceEmbedded) {
            aggregator.fetchEmbeddedChapters(book)
                .getOrNull()
                ?.takeIf { it.isNotEmpty() }
                ?: aggregator.fetchChapters(book).getOrNull()
        } else {
            aggregator.fetchChapters(book).getOrNull()
        }
        return chapters?.also { applyFetchedChapters(book, it) }
    }

    private suspend fun cachedChapters(book: Book): List<Chapter>? {
        val keys = listOfNotNull(
            book.uniqueKey,
            bookCache.getByIdAndConnection(book.id, book.connectionId)?.cacheKey,
            bookCache.getById(book.id)?.cacheKey,
        ).distinct()
        return keys.firstNotNullOfOrNull { key ->
            bookExtras.get(key)?.decodeChapters()?.takeIf { it.isNotEmpty() }
        }
    }

    private suspend fun applyFetchedChapters(book: Book, chapters: List<Chapter>) {
        if (chapters.isEmpty()) return

        val existing = bookExtras.get(book.uniqueKey)
        bookExtras.upsert(
            BookExtras(
                cacheKey = book.uniqueKey,
                chaptersJson = encodeChaptersJson(chapters),
                audioTracksJson = existing?.audioTracksJson ?: "[]",
                updatedAt = System.currentTimeMillis(),
            ),
        )

        val active = chapterStore.snapshot.value
        if (active.isBook(book) || isCurrentPlaybackBook(book)) {
            chapterStore.set(
                cacheKey = book.uniqueKey,
                bookId = book.id,
                chapters = chapters,
                title = book.title,
                author = book.author,
                coverUrl = book.coverUrl,
            )
        }
    }

    private suspend fun isCurrentPlaybackBook(book: Book): Boolean {
        val currentId = audioManager.currentBookId ?: return false
        if (currentId == book.id) return true
        val current = bookCache.getById(currentId) ?: return false
        return current.cacheKey == book.uniqueKey
    }

    private fun PlaybackChapterStore.Snapshot.isBook(book: Book): Boolean =
        bookId == book.id || cacheKey == book.uniqueKey
}

internal fun Book.usesOfflineAudioDownload(): Boolean =
    !(source == BookSource.STORYTELLER && readAlongAvailable) &&
        (mediaType == AppMediaType.AUDIOBOOK || hasAudio)

private fun Book.withActualDownloadState(
    audioDownloadedIds: Set<String>,
    comicDownloadedIds: Set<String>,
): Book {
    val actualDownloaded = if (usesOfflineAudioDownload()) {
        id in audioDownloadedIds
    } else {
        id in comicDownloadedIds
    }
    return if (isDownloaded == actualDownloaded) this else copy(isDownloaded = actualDownloaded)
}

internal enum class ShelfKind { GRIMMORY_REGULAR, GRIMMORY_MAGIC, BOOKORBIT }

internal data class ShelfRef(
    val connectionId: String,
    val shelfId: Long,
    val kind: ShelfKind,
)

private fun shelfKey(connectionId: String, shelfId: Long, magic: Boolean): String =
    listOf(connectionId, if (magic) "magic" else "regular", shelfId.toString()).joinToString("|")

private fun bookOrbitShelfKey(connectionId: String, collectionId: Int): String =
    listOf(connectionId, "bookorbit", collectionId.toString()).joinToString("|")

internal object BookOrbitCollectionPolicy {
    fun bookIds(connectionId: String, books: List<Book>): List<Int>? {
        if (books.isEmpty() || books.any { it.source != BookSource.BOOKORBIT || it.connectionId != connectionId }) return null
        val ids = books.map { it.id.toIntOrNull() ?: return null }.distinct()
        return ids.takeIf { it.isNotEmpty() }
    }
}

internal fun parseShelfKey(key: String): ShelfRef? {
    val shelfSeparator = key.lastIndexOf('|')
    if (shelfSeparator <= 0 || shelfSeparator == key.lastIndex) return null
    val kindSeparator = key.lastIndexOf('|', shelfSeparator - 1)
    if (kindSeparator <= 0) return null
    val shelfId = key.substring(shelfSeparator + 1).toLongOrNull() ?: return null
    val kind = when (key.substring(kindSeparator + 1, shelfSeparator)) {
        "magic" -> ShelfKind.GRIMMORY_MAGIC
        "regular" -> ShelfKind.GRIMMORY_REGULAR
        "bookorbit" -> ShelfKind.BOOKORBIT
        else -> return null
    }
    return ShelfRef(key.substring(0, kindSeparator), shelfId, kind)
}

private fun BookOrbitCollectionDto.toBrowseGroup(connectionId: String, editable: Boolean): BrowseGroup = BrowseGroup(
    key = bookOrbitShelfKey(connectionId, id),
    name = name,
    count = bookCount,
    secondary = "BookOrbit collection",
    sourceConnectionId = connectionId,
    source = BookSource.BOOKORBIT,
    description = description,
    icon = icon,
    isEditable = editable,
    syncToKobo = syncToKobo,
    displayOrder = displayOrder,
)

private fun BookOrbitCollectionEdit.toRequest(): BookOrbitCollectionRequest = BookOrbitCollectionRequest(
    name = name.trim(),
    icon = icon,
    description = description?.trim()?.takeIf { it.isNotEmpty() },
    syncToKobo = syncToKobo,
)

private fun OfflineDownloadProgress.toLibraryDownloadState(): LibraryDownloadState =
    LibraryDownloadState(
        status = status.toLibraryDownloadStatus(),
        progress = progress.coerceIn(0f, 1f),
        completedItems = completedTracks,
        totalItems = totalTracks,
        errorMessage = errorMessage,
    )

private fun OfflineDownloadStatus.toLibraryDownloadStatus(): LibraryDownloadStatus = when (this) {
    OfflineDownloadStatus.QUEUED -> LibraryDownloadStatus.QUEUED
    OfflineDownloadStatus.DOWNLOADING -> LibraryDownloadStatus.DOWNLOADING
    OfflineDownloadStatus.COMPLETED -> LibraryDownloadStatus.COMPLETED
    OfflineDownloadStatus.FAILED -> LibraryDownloadStatus.FAILED
    OfflineDownloadStatus.CANCELLED -> LibraryDownloadStatus.CANCELLED
}

private fun ComicDownloadProgress.toLibraryDownloadState(): LibraryDownloadState =
    LibraryDownloadState(
        status = status.toLibraryDownloadStatus(),
        progress = progress.coerceIn(0f, 1f),
        completedItems = if (status == ComicDownloadStatus.COMPLETED) 1 else 0,
        totalItems = 1,
        errorMessage = errorMessage,
    )

private fun ComicDownloadStatus.toLibraryDownloadStatus(): LibraryDownloadStatus = when (this) {
    ComicDownloadStatus.QUEUED -> LibraryDownloadStatus.QUEUED
    ComicDownloadStatus.DOWNLOADING -> LibraryDownloadStatus.DOWNLOADING
    ComicDownloadStatus.COMPLETED -> LibraryDownloadStatus.COMPLETED
    ComicDownloadStatus.CANCELLED -> LibraryDownloadStatus.CANCELLED
    ComicDownloadStatus.FAILED -> LibraryDownloadStatus.FAILED
}

private fun LibraryMetadataEdit.toProviderUpdate(): ProviderMetadataUpdate =
    ProviderMetadataUpdate(
        title = title,
        subtitle = subtitle,
        author = author,
        narrator = narrator,
        description = description,
        seriesName = seriesName,
        seriesNumber = seriesNumber,
        publisher = publisher,
        publishedDate = publishedDate,
        isbn13 = isbn13,
        language = language,
        pageCount = pageCount,
        categories = categories,
    )

private fun MetadataMatchCandidate.toLibraryMatch(): LibraryMetadataMatch =
    LibraryMetadataMatch(
        id = id,
        externalId = externalId,
        sourceName = source.name,
        title = title,
        subtitle = subtitle,
        author = author,
        narrator = narrator,
        publisher = publisher,
        publishedDate = publishedDate,
        publishedYear = publishedYear,
        isbn = isbn,
        coverUrl = coverUrl,
        durationSec = durationSec,
        pageCount = pageCount,
        seriesName = seriesName,
        seriesPosition = seriesPosition,
        description = description,
        categories = categories,
        language = language,
        confidence = confidence,
        matchReason = matchReason,
    )

private fun LibraryMetadataMatch.toCandidate(mediaType: AppMediaType): MetadataMatchCandidate =
    MetadataMatchCandidate(
        id = id,
        externalId = externalId,
        source = MetadataCandidateSource.valueOf(sourceName),
        mediaType = mediaType,
        title = title,
        subtitle = subtitle,
        author = author,
        authors = author?.let(::listOf).orEmpty(),
        narrator = narrator,
        narrators = narrator?.let(::listOf).orEmpty(),
        publisher = publisher,
        publishedDate = publishedDate,
        publishedYear = publishedYear,
        isbn = isbn,
        coverUrl = coverUrl,
        durationSec = durationSec,
        pageCount = pageCount,
        seriesName = seriesName,
        seriesPosition = seriesPosition,
        description = description,
        categories = categories,
        language = language,
        confidence = confidence,
        matchReason = matchReason,
    )
