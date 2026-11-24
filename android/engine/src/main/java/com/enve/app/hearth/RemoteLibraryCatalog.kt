package com.enve.app.hearth

import com.enve.app.data.offline.ComicOfflineService
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.offline.offlineDownloadKey
import com.enve.app.data.repository.LibraryCacheRepository
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.LibraryCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.local.toCached
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.local.toLibrary
import com.enve.core.data.model.Book
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.RemoteCatalogBrowsingProvider
import com.enve.core.data.provider.RemoteCatalogFilterOptions
import com.enve.core.data.provider.RemoteCatalogRequest
import com.enve.core.data.provider.RemoteCatalogSort
import com.enve.core.di.ApplicationScope
import com.enve.core.data.remote.ConnectionScope
import com.enve.engine.library.RemoteLibraryFilterOptions
import com.enve.engine.library.RemoteLibraryPage
import com.enve.engine.library.RemoteLibraryRequest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.text.Normalizer
import java.util.Locale
import javax.inject.Inject

class RemoteLibraryCatalog @Inject constructor(
    private val adapters: Set<@JvmSuppressWildcards ProviderAdapter>,
    private val connections: ConnectionRegistry,
    private val libraries: LibraryCacheDao,
    private val books: BookCacheDao,
    private val cache: LibraryCacheRepository,
    private val audioDownloads: OfflineDownloadManager,
    private val ebookDownloads: ComicOfflineService,
    @ApplicationScope private val runtimeScope: CoroutineScope,
) {
    private data class Lane(
        val connection: ProviderConnection,
        val library: Library,
        val provider: RemoteCatalogBrowsingProvider,
        val discoveryFailure: Exception? = null,
    ) {
        fun scoped(request: RemoteLibraryRequest): RemoteLibraryRequest = request.copy(
            connectionId = connection.id,
            libraryId = if (discoveryFailure == null) library.id else request.libraryId,
        )
    }

    suspend fun page(request: RemoteLibraryRequest, cursors: Map<String, String>?): RemoteLibraryPage = withCatalogRuntime(runtimeScope) {
        val lanes = try {
            lanes(request)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            return@withCatalogRuntime if (remoteCatalogUnavailable(error)) {
                RemoteLibraryPage(offlineBooks(request), offline = true)
            } else RemoteLibraryPage(error = "Couldn't load the server library. Retry or check your connection settings.")
        }
        val active = lanes.filter { cursors == null || it.library.id in cursors }
        val pages = coroutineScope {
            active.map { lane -> async {
                try {
                    lane.discoveryFailure?.let { throw it }
                    val page = interactive(lane.connection) {
                        lane.provider.fetchRemoteCatalogPage(lane.library.id.substringAfter("::"), request.catalog, cursors?.get(lane.library.id), 50)
                    }
                    if (!isCurrent(lane.connection)) throw CancellationException("Library connection changed")
                    val scoped = page.books.map { it.copy(connectionId = lane.connection.id, libraryId = lane.library.id, libraryName = lane.library.name) }
                    val existing = books.getByCacheKeys(scoped.map(Book::uniqueKey)).associateBy { it.cacheKey }
                    books.insertIfAbsent(scoped.filter { it.uniqueKey !in existing }.map { it.toCachedBook() })
                    RemoteLibraryPage(
                        books = scoped.map { summary -> overlayRemoteSummary(summary, existing[summary.uniqueKey]?.toBook()) },
                        nextCursors = page.nextCursor?.let { mapOf(lane.library.id to it) }.orEmpty(),
                    )
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    if (remoteCatalogUnavailable(error)) {
                        RemoteLibraryPage(offlineBooks(lane.scoped(request)), offline = true)
                    } else RemoteLibraryPage(error = "Couldn't load some server results. Retry or check your connection settings.")
                }
            } }.awaitAll()
        }
        RemoteLibraryPage(
            books = remoteSortedBooks(pages.flatMap { it.books }.distinctBy(Book::uniqueKey), request.catalog.sort),
            nextCursors = pages.flatMap { it.nextCursors.entries }.associate { it.toPair() },
            offline = pages.any { it.offline },
            error = pages.firstNotNullOfOrNull { it.error },
        )
    }

    suspend fun filterOptions(request: RemoteLibraryRequest, search: String): RemoteLibraryFilterOptions = withCatalogRuntime(runtimeScope) {
        val lanes = try {
            lanes(request)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            val options = remoteFilterOptions(offlineBooks(request.copy(catalog = request.catalog.copy(search = "", genres = emptySet(), languages = emptySet()))), search)
            return@withCatalogRuntime RemoteLibraryFilterOptions(options, "Server filters unavailable. Showing downloaded-book filters.")
        }
        val results = coroutineScope {
            lanes.map { lane -> async {
                try {
                    lane.discoveryFailure?.let { throw it }
                    val options = interactive(lane.connection) {
                        lane.provider.fetchRemoteCatalogFilterOptions(lane.library.id.substringAfter("::"), request.catalog.mediaType, search)
                    }
                    if (!isCurrent(lane.connection)) throw CancellationException("Library connection changed")
                    RemoteLibraryFilterOptions(options)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    val local = offlineBooks(lane.scoped(request).copy(
                        catalog = request.catalog.copy(search = "", genres = emptySet(), languages = emptySet())))
                    RemoteLibraryFilterOptions(remoteFilterOptions(local, search),
                        if (error is UnsupportedOperationException) "Update Silo to search server filter values. Showing downloaded-book filters."
                        else "Server filters unavailable. Showing downloaded-book filters.")
                }
            } }.awaitAll()
        }
        RemoteLibraryFilterOptions(
            options = RemoteCatalogFilterOptions(
                genres = remoteUniqueValues(results.flatMap { it.options.genres }),
                languages = remoteUniqueValues(results.flatMap { it.options.languages }),
                hasMore = results.any { it.options.hasMore },
            ),
            error = results.firstNotNullOfOrNull { it.error },
        )
    }

    suspend fun detail(book: Book): Book? = withCatalogRuntime(runtimeScope) {
        val provider = adapters.filterIsInstance<RemoteCatalogBrowsingProvider>().firstOrNull { it.source == book.source } ?: return@withCatalogRuntime null
        val connection = connections.connections.first().firstOrNull { it.id == book.connectionId && it.enabled && it.source == book.source }
            ?: return@withCatalogRuntime null
        try {
            val detail = interactive(connection) { provider.fetchRemoteCatalogDetail(book.copy(libraryId = book.libraryId?.substringAfter("::"))) }
            if (!isCurrent(connection)) throw CancellationException("Library connection changed")
            cache.cacheRemoteDetail(detail.copy(
                connectionId = book.connectionId,
                libraryId = book.libraryId,
                libraryName = book.libraryName,
                language = detail.language ?: book.language,
                categories = detail.categories.ifEmpty { book.categories },
            ))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (remoteCatalogUnavailable(error) && (audioDownloads.isDownloaded(book.offlineDownloadKey) || ebookDownloads.isDownloaded(book.offlineDownloadKey))) {
                book.copy(isDownloaded = true)
            } else throw error
        }
    }

    private suspend fun lanes(request: RemoteLibraryRequest): List<Lane> = coroutineScope {
        val providers = adapters.filterIsInstance<RemoteCatalogBrowsingProvider>().associateBy { it.source }
        val cached = libraries.getAll().map { it.toLibrary() }
        val selectedLibrary = request.libraryId
        connections.connections.first().filter { connection ->
            connection.enabled && connection.source in providers &&
                (request.source == null || connection.source == request.source) &&
                (request.connectionId == null || connection.id == request.connectionId) &&
                (selectedLibrary == null || !selectedLibrary.contains("::") || selectedLibrary.substringBefore("::") == connection.id)
        }.map { connection -> async {
            val provider = providers.getValue(connection.source)
            try {
                val known = cached.filter { it.connectionId == connection.id && it.source == connection.source }
                val available = if (known.isNotEmpty()) known else {
                    val adapter = adapters.first { it.source == connection.source }
                    interactive(connection) { adapter.getLibraries().getOrThrow() }.map { library ->
                        library.copy(id = "${connection.id}::${library.id.substringAfter("::")}", connectionId = connection.id)
                    }.also { rows ->
                        if (!isCurrent(connection)) throw CancellationException("Library connection changed")
                        libraries.upsert(rows.map { it.toCached() })
                    }
                }
                available.filter { library ->
                    library.id !in request.excludedLibraryIds &&
                        (request.libraryId == null || request.libraryId == library.id)
                }.map { Lane(connection, it, provider) }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                listOf(Lane(connection, Library(
                    id = request.libraryId ?: "${connection.id}::",
                    name = connection.name,
                    source = connection.source,
                    connectionId = connection.id,
                ), provider, error))
            }
        } }.awaitAll().flatten()
    }

    private suspend fun offlineBooks(request: RemoteLibraryRequest): List<Book> {
        val enabled = connections.connections.first().filter { it.enabled }.associateBy { it.id }
        val audio = audioDownloads.listDownloadedManifests().mapNotNull { manifest ->
            books.getByCacheKey("${manifest.connectionId ?: manifest.source}:${manifest.bookId}")?.toBook()
        }
        val ebooks = ebookDownloads.listDownloadedManifests().filter { ebookDownloads.isDownloaded(it.offlineDownloadKey) }.map { manifest ->
            val cached = books.getByCacheKey(manifest.uniqueKey)?.toBook()
            (cached ?: manifest).copy(language = cached?.language ?: manifest.language, categories = cached?.categories?.ifEmpty { manifest.categories } ?: manifest.categories)
        }
        return (audio + ebooks).asSequence().filter { book ->
            enabled[book.connectionId]?.source == book.source &&
                (request.source == null || request.source == book.source) &&
                (request.connectionId == null || request.connectionId == book.connectionId) &&
                (request.libraryId == null || request.libraryId == book.libraryId) &&
                book.libraryId !in request.excludedLibraryIds && remoteCatalogMatches(book, request.catalog)
        }.distinctBy(Book::uniqueKey).map { it.copy(isDownloaded = true) }.toList().let { selected ->
            remoteSortedBooks(selected, request.catalog.sort)
        }
    }

    private suspend fun isCurrent(connection: ProviderConnection): Boolean =
        connections.connections.first().any { it.copy(lastSyncedAt = null) == connection.copy(lastSyncedAt = null) }

    private suspend fun <T : Any> interactive(connection: ProviderConnection, block: suspend () -> T): T =
        withContext(ConnectionScope.asContextElement(connection.id)) {
            withTimeoutOrNull(8_000) { block() } ?: throw SocketTimeoutException("Catalog request timed out")
        }
}

internal fun overlayRemoteSummary(summary: Book, stored: Book?): Book = if (stored == null) summary else summary.copy(
    author = summary.author ?: stored.author,
    narrator = summary.narrator ?: stored.narrator,
    seriesName = summary.seriesName ?: stored.seriesName,
    seriesNumber = summary.seriesNumber ?: stored.seriesNumber,
    description = summary.description ?: stored.description,
    publisher = summary.publisher ?: stored.publisher,
    primaryFileType = summary.primaryFileType ?: stored.primaryFileType,
    duration = summary.duration.takeIf { it > 0 } ?: stored.duration,
    addedOn = summary.addedOn.takeIf { it > 0 } ?: stored.addedOn,
    goodreadsRating = stored.goodreadsRating,
    currentTime = stored.currentTime,
    readProgress = stored.readProgress,
    epubProgress = stored.epubProgress,
    epubLocator = stored.epubLocator,
    lastReadTime = stored.lastReadTime,
    isFinished = stored.isFinished,
    readStatus = stored.readStatus,
    hideFromContinue = stored.hideFromContinue,
    isDownloaded = stored.isDownloaded,
    personalRating = stored.personalRating,
    language = summary.language ?: stored.language,
    categories = summary.categories.ifEmpty { stored.categories },
)

internal fun remoteCatalogMatches(book: Book, request: RemoteCatalogRequest): Boolean {
    if (request.mediaType != null && book.mediaType != request.mediaType) return false
    val genres = request.genres.map(::remoteFold).toSet()
    if (genres.isNotEmpty() && book.categories.none { remoteFold(it) in genres }) return false
    val languages = request.languages.map(::remoteFold).toSet()
    if (languages.isNotEmpty() && book.language?.let(::remoteFold) !in languages) return false
    val haystack = remoteFold(listOfNotNull(book.title, book.author, book.narrator, book.seriesName).joinToString(" "))
    return remoteFold(request.search).split(Regex("\\s+")).all(haystack::contains)
}

internal fun remoteCatalogUnavailable(error: Throwable): Boolean =
    error is UnknownHostException || error is ConnectException || error is NoRouteToHostException ||
        error is SocketTimeoutException || error is SocketException

private fun remoteFilterOptions(books: List<Book>, search: String): RemoteCatalogFilterOptions {
    val needle = remoteFold(search)
    return RemoteCatalogFilterOptions(
        genres = remoteUniqueValues(books.flatMap(Book::categories)).filter { remoteFold(it).contains(needle) },
        languages = remoteUniqueValues(books.mapNotNull(Book::language)).filter { remoteFold(it).contains(needle) },
    )
}

private fun remoteUniqueValues(values: List<String>): List<String> =
    values.map(String::trim).filter(String::isNotEmpty).distinctBy(::remoteFold).sortedWith(String.CASE_INSENSITIVE_ORDER)

private fun remoteFold(value: String): String =
    Normalizer.normalize(value.trim(), Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase(Locale.ROOT)

private fun remoteSortedBooks(books: List<Book>, sort: RemoteCatalogSort): List<Book> = when (sort) {
    RemoteCatalogSort.TITLE -> books.sortedWith(compareBy<Book> { remoteFold(it.title) }.thenBy(Book::uniqueKey))
    RemoteCatalogSort.RECENTLY_ADDED -> books.sortedWith(compareByDescending<Book> { it.addedOn }.thenBy { remoteFold(it.title) }.thenBy(Book::uniqueKey))
}

internal suspend fun <T> withCatalogRuntime(scope: CoroutineScope, block: suspend () -> T): T {
    currentCoroutineContext().ensureActive()
    val operation = scope.async(Dispatchers.IO) { block() }
    try {
        return operation.await()
    } finally {
        withContext(NonCancellable) { operation.cancelAndJoin() }
    }
}
