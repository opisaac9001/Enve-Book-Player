package com.enve.hearth.library

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.RemoteCatalogRequest
import com.enve.core.data.provider.RemoteCatalogSort
import com.enve.engine.library.RemoteLibraryFilterOptions
import com.enve.engine.library.RemoteLibraryPage
import com.enve.engine.library.RemoteLibraryRequest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

internal const val REMOTE_SEARCH_DEBOUNCE_MS = 250L
internal const val REMOTE_FILTER_OPTION_CAP = 24

data class LibraryCatalogPlan(
    val request: RemoteLibraryRequest? = null,
    val siloInScope: Boolean = false,
    val cachedReasons: List<String> = emptyList(),
    val sortFallback: Boolean = false,
) {
    val live: Boolean get() = request != null

    val cachedNotice: String?
        get() = cachedReasons.takeIf { it.isNotEmpty() }?.let { reasons ->
            "Silo can't search with ${reasons.joinToString(" or ")}, so Silo results come from cached books only and may be incomplete."
        }

    val sortNotice: String?
        get() = if (live && sortFallback) "Silo can only sort by title or recently added, so results are shown by title." else null
}

data class LibraryCatalogStatus(
    val live: Boolean = false,
    val cachedNotice: String? = null,
    val sortNotice: String? = null,
    val loading: Boolean = false,
    val offline: Boolean = false,
    val error: String? = null,
    val hasMore: Boolean = false,
)

data class LibraryFilterOptionsState(
    val genres: List<String> = emptyList(),
    val languages: List<String> = emptyList(),
    val hasMore: Boolean = false,
    val loading: Boolean = false,
    val error: String? = null,
    val remote: Boolean = false,
)

internal fun libraryCatalogPlan(
    facet: LibraryFacet,
    status: StatusFilter,
    media: MediaFilter,
    selection: LibrarySelection,
    scopeSource: BookSource?,
    advanced: LibraryAdvancedFilters,
    sort: List<SortDescriptor>,
    query: String,
    siloEnabled: Boolean,
    excludedLibraryIds: Set<String>,
    readingEnabled: Boolean,
): LibraryCatalogPlan {
    if (!siloEnabled || (scopeSource != null && scopeSource != BookSource.SILO) || facet == LibraryFacet.SHELVES) {
        return LibraryCatalogPlan()
    }
    val reasons = buildList {
        if (facet != LibraryFacet.BOOKS) add("grouping by ${facet.name.lowercase()}")
        if (status != StatusFilter.ALL) add("status filters")
        if (media == MediaFilter.COMICS) add("comic browsing")
        if (advanced.minimumRating != null) add("rating filters")
        if (advanced.series != SeriesFilter.ALL) add("series filters")
    }
    if (reasons.isNotEmpty()) return LibraryCatalogPlan(siloInScope = true, cachedReasons = reasons)
    val remoteSort = remoteCatalogSort(sort)
    val request = RemoteLibraryRequest(
        catalog = RemoteCatalogRequest(
            search = query.trim(),
            mediaType = when (media) {
                MediaFilter.AUDIOBOOKS -> AppMediaType.AUDIOBOOK
                MediaFilter.EBOOKS -> AppMediaType.EBOOK
                else -> if (readingEnabled) null else AppMediaType.AUDIOBOOK
            },
            sort = remoteSort ?: RemoteCatalogSort.TITLE,
            genres = advanced.genres,
            languages = advanced.languages,
        ),
        source = scopeSource,
        libraryId = selection.libraryId,
        connectionId = selection.connectionId,
        excludedLibraryIds = excludedLibraryIds,
    )
    return LibraryCatalogPlan(request = request, siloInScope = true, sortFallback = remoteSort == null)
}

internal fun remoteCatalogSort(stack: List<SortDescriptor>): RemoteCatalogSort? {
    val descriptor = stack.ifEmpty { DEFAULT_SORT }.singleOrNull() ?: return null
    return when {
        descriptor.field == LibrarySort.TITLE && descriptor.direction == SortDirection.ASCENDING -> RemoteCatalogSort.TITLE
        descriptor.field == LibrarySort.RECENT && descriptor.direction == SortDirection.DESCENDING -> RemoteCatalogSort.RECENTLY_ADDED
        else -> null
    }
}

internal fun remoteCatalogComparator(sort: RemoteCatalogSort): Comparator<Book> = when (sort) {
    RemoteCatalogSort.TITLE -> compareBy(String.CASE_INSENSITIVE_ORDER, Book::title)
    RemoteCatalogSort.RECENTLY_ADDED -> compareByDescending<Book> { it.addedOn }
        .thenBy(String.CASE_INSENSITIVE_ORDER, Book::title)
}

internal fun mergeCatalogPages(
    local: List<Book>,
    remote: List<Book>,
    comparator: Comparator<Book>,
    remoteHasMore: Boolean,
): List<Book> {
    val sortedLocal = local.sortedWith(comparator)
    val boundary = remote.lastOrNull()
    val shownLocal = if (remoteHasMore && boundary != null) {
        sortedLocal.filter { comparator.compare(it, boundary) <= 0 }
    } else {
        sortedLocal
    }
    val merged = ArrayList<Book>(shownLocal.size + remote.size)
    var l = 0
    var r = 0
    while (l < shownLocal.size || r < remote.size) {
        merged += when {
            l == shownLocal.size -> remote[r++]
            r == remote.size -> shownLocal[l++]
            comparator.compare(shownLocal[l], remote[r]) <= 0 -> shownLocal[l++]
            else -> remote[r++]
        }
    }
    return merged.distinctBy(Book::uniqueKey)
}

internal fun visibleFilterOptions(
    available: List<String>,
    selected: Set<String>,
    typeahead: String,
    cap: Int = REMOTE_FILTER_OPTION_CAP,
): Pair<List<String>, Boolean> {
    val needle = typeahead.trim()
    val selectedKeys = selected.mapTo(mutableSetOf()) { it.lowercase() }
    val matching = available.asSequence()
        .map(String::trim)
        .filter { it.isNotEmpty() && it.lowercase() !in selectedKeys }
        .filter { needle.isEmpty() || it.contains(needle, ignoreCase = true) }
        .distinctBy(String::lowercase)
        .toList()
    val shown = (selected + matching.take(cap)).sortedWith(String.CASE_INSENSITIVE_ORDER)
    return shown to (matching.size > cap)
}

internal data class RemoteCatalogState(
    val request: RemoteLibraryRequest? = null,
    val books: List<Book> = emptyList(),
    val nextCursors: Map<String, String> = emptyMap(),
    val retryCursors: Map<String, String>? = null,
    val loading: Boolean = false,
    val offline: Boolean = false,
    val error: String? = null,
) {
    val hasMore: Boolean get() = nextCursors.isNotEmpty()
}

internal class RemoteCatalogPager(
    private val scope: CoroutineScope,
    private val load: suspend (RemoteLibraryRequest, Map<String, String>?) -> RemoteLibraryPage,
) {
    private val _state = MutableStateFlow(RemoteCatalogState())
    val state: StateFlow<RemoteCatalogState> = _state.asStateFlow()
    private var identity: Any? = null
    private var job: Job? = null
    private var generation = 0L

    fun submit(request: RemoteLibraryRequest?, scopeKey: Any? = null) {
        val next = request to scopeKey
        if (next == identity) return
        val previous = _state.value.request
        identity = next
        val searchOnly = previous != null && request != null &&
            previous.catalog.search != request.catalog.search &&
            previous == request.copy(catalog = request.catalog.copy(search = previous.catalog.search))
        start(request, if (searchOnly) REMOTE_SEARCH_DEBOUNCE_MS else 0L)
    }

    fun reload() = start(_state.value.request, 0L)

    fun loadMore() {
        val current = _state.value
        val request = current.request ?: return
        if (current.loading || current.error != null || !current.hasMore) return
        fetch(request, current.nextCursors, 0L)
    }

    fun retry() {
        val current = _state.value
        val request = current.request ?: return
        if (current.loading) return
        fetch(request, current.retryCursors, 0L)
    }

    private fun start(request: RemoteLibraryRequest?, debounceMs: Long) {
        job?.cancel()
        generation += 1
        _state.value = RemoteCatalogState(request = request, loading = request != null)
        if (request != null) fetch(request, null, debounceMs)
    }

    private fun fetch(request: RemoteLibraryRequest, cursors: Map<String, String>?, debounceMs: Long) {
        job?.cancel()
        val token = ++generation
        _state.value = _state.value.copy(loading = true, error = null, retryCursors = cursors)
        job = scope.launch {
            if (debounceMs > 0) delay(debounceMs)
            val page = try {
                load(request, cursors)
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (error: Exception) {
                RemoteLibraryPage(error = "Couldn't load server results. Please retry.")
            }
            if (token != generation) return@launch
            val current = _state.value
            val base = if (cursors == null) emptyList() else current.books
            _state.value = current.copy(
                books = (base + page.books).distinctBy(Book::uniqueKey).sortedWith(remoteCatalogComparator(request.catalog.sort)),
                nextCursors = if (page.error != null && page.nextCursors.isEmpty()) cursors.orEmpty() else page.nextCursors,
                loading = false,
                offline = page.offline,
                error = page.error,
            )
        }
    }
}

internal fun filterOptionsScope(request: RemoteLibraryRequest): RemoteLibraryRequest =
    request.copy(catalog = RemoteCatalogRequest(mediaType = request.catalog.mediaType))

internal data class RemoteFilterOptionsRequest(val request: RemoteLibraryRequest, val search: String)

internal data class RemoteFilterOptionsResult(
    val key: RemoteFilterOptionsRequest? = null,
    val options: RemoteLibraryFilterOptions? = null,
    val loading: Boolean = false,
)

internal class RemoteFilterOptionsLoader(
    private val scope: CoroutineScope,
    private val load: suspend (RemoteLibraryRequest, String) -> RemoteLibraryFilterOptions,
) {
    private val _state = MutableStateFlow(RemoteFilterOptionsResult())
    val state: StateFlow<RemoteFilterOptionsResult> = _state.asStateFlow()
    private var job: Job? = null
    private var generation = 0L

    fun submit(key: RemoteFilterOptionsRequest?, force: Boolean = false) {
        val previous = _state.value.key
        if (key == previous && !force) return
        job?.cancel()
        val token = ++generation
        _state.value = RemoteFilterOptionsResult(key = key, loading = key != null)
        if (key == null) return
        val debounce = previous != null && previous.request == key.request && previous.search != key.search
        job = scope.launch {
            if (debounce) delay(REMOTE_SEARCH_DEBOUNCE_MS)
            val options = try {
                load(key.request, key.search)
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (error: Exception) {
                RemoteLibraryFilterOptions(error = "Couldn't load filter options. Please retry.")
            }
            if (token == generation) _state.value = RemoteFilterOptionsResult(key = key, options = options)
        }
    }

    fun retry() = submit(_state.value.key, force = true)
}
