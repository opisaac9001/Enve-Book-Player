package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.paging.LoadState
import androidx.paging.LoadStates
import androidx.paging.Pager
import androidx.paging.PagingConfig
import androidx.paging.PagingData
import androidx.paging.PagingSource
import androidx.paging.PagingState
import androidx.paging.cachedIn
import androidx.paging.filter
import androidx.paging.map
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.util.NaturalSort
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookCardStyle
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.visibleLibraryBooks
import com.enve.core.data.model.Library
import com.enve.core.data.model.LibraryLayout
import com.enve.core.data.model.MergeAggressiveness
import com.enve.core.data.model.ReadStatus
import com.enve.core.data.model.SortDirection
import com.enve.core.data.model.SortOption
import com.enve.core.data.model.SubtitleHandling
import com.enve.core.data.model.TitleDisplayMode
import com.enve.core.data.model.toLegacyLibrary
import com.enve.core.data.model.toShallowBook
import com.enve.core.data.remote.ConnectionScope
import com.enve.app.data.paging.AudiobookshelfBooksPagingSource
import com.enve.app.data.paging.BookOrbitBooksPagingSource
import com.enve.app.data.paging.GrimmoryBooksPagingSource
import com.enve.app.data.paging.KomgaBooksPagingSource
import com.enve.app.data.paging.OpdsBooksPagingSource
import com.enve.app.data.metadata.LibraryMetadataRefreshRepository
import com.enve.app.data.metadata.LibraryMetadataRefreshSummary
import com.enve.app.data.repository.AggregatorRepository
import com.enve.audiobookshelf.AudiobookshelfRepository
import com.enve.bookorbit.BookOrbitRepository
import com.enve.app.data.repository.GrimmoryAppRepository
import com.enve.komga.KomgaRepository
import com.enve.app.data.repository.LibraryCacheRepository
import com.enve.app.data.repository.LibraryListResolver
import com.enve.app.data.repository.OpdsRepository
import com.enve.storyteller.StorytellerRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale
import javax.inject.Inject

data class LibraryState(
    val libraries: List<Library> = emptyList(),

    val connections: List<com.enve.core.data.model.ProviderConnection> = emptyList(),
    val selectedLibraryId: String? = null,
    val searchQuery: String = "",
    val sortOption: SortOption = SortOption.DATE_ADDED,
    val secondarySortOption: SortOption? = null,
    val sortDirection: SortDirection = SortDirection.DESCENDING,
    val layout: LibraryLayout = LibraryLayout.TWO_COLUMN,
    val isLoading: Boolean = true,
    val isRefreshing: Boolean = false,
    val error: String? = null,
    val selectedFilter: ReadStatus? = null,
    val mediaType: AppMediaType = AppMediaType.AUDIOBOOK,
    val showDownloadedOnly: Boolean = false,
    val showInProgressOnly: Boolean = false,
    val showCompletedOnly: Boolean = false,
    val showNotStartedOnly: Boolean = false,
    val isSelectionMode: Boolean = false,
    val selectedBookIds: Set<String> = emptySet(),
    val seriesFilter: String? = null,
    val authorFilter: String? = null,
    val genreFilter: String? = null,
    val hiddenBookIds: Set<String> = emptySet(),
    val excludedLibraryIds: Set<String> = emptySet(),
    val totalBookCount: Int = 0,
    val bookCardStyle: BookCardStyle = BookCardStyle.STANDARD,
    val titleDisplayMode: TitleDisplayMode = TitleDisplayMode.PRESERVE,
    val subtitleHandling: SubtitleHandling = SubtitleHandling.KEEP,
    val mergeAggressiveness: MergeAggressiveness = MergeAggressiveness.NORMAL,
    val showAdvancedLibrarySettings: Boolean = false,
    val authorGroupingThreshold: Float = 0.85f,
) {
    val hasActiveFilters: Boolean
        get() = showDownloadedOnly || showInProgressOnly || showCompletedOnly || showNotStartedOnly ||
            selectedFilter != null || !authorFilter.isNullOrBlank() || !genreFilter.isNullOrBlank() ||
            sortOption != SortOption.DATE_ADDED ||
            sortDirection != SortDirection.DESCENDING || secondarySortOption != null
}

@OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
@HiltViewModel
class LibraryViewModel @Inject constructor(
    private val bookloreRepository: GrimmoryAppRepository,
    private val komgaRepository: KomgaRepository,
    private val absRepository: AudiobookshelfRepository,
    private val opdsRepository: OpdsRepository,
    private val storytellerRepository: StorytellerRepository,
    private val bookOrbitRepository: BookOrbitRepository,
    private val libraryListResolver: LibraryListResolver,
    private val aggregatorRepository: AggregatorRepository,
    private val libraryCacheRepository: LibraryCacheRepository,
    private val libraryMetadataRefreshRepository: LibraryMetadataRefreshRepository,
    private val prefs: PreferencesManager,
    private val connectionRegistry: ConnectionRegistry,
    private val offlineDownloadManager: com.enve.app.data.offline.OfflineDownloadManager,
    private val comicOfflineService: com.enve.app.data.offline.ComicOfflineService,
) : ViewModel() {

    private val _state = MutableStateFlow(LibraryState())
    val state: StateFlow<LibraryState> = _state.asStateFlow()

    init {

        viewModelScope.launch {
            android.util.Log.i("LibraryViewModel", "init hydrate: starting prefs read")
            try {
                val sortOption = runCatching { SortOption.valueOf(prefs.librarySortOption.first()) }
                    .getOrDefault(SortOption.DATE_ADDED)
                android.util.Log.i("LibraryViewModel", "init hydrate: read sortOption=${sortOption.name}")
                val secondarySortRaw = prefs.librarySortSecondary.first()
                android.util.Log.i("LibraryViewModel", "init hydrate: read secondarySortRaw='$secondarySortRaw'")
                val secondarySortOption = secondarySortRaw.takeIf { it.isNotBlank() }
                    ?.let { runCatching { SortOption.valueOf(it) }.getOrNull() }
                val sortDirection = runCatching { SortDirection.valueOf(prefs.librarySortDirection.first()) }
                    .getOrDefault(SortDirection.DESCENDING)
                android.util.Log.i("LibraryViewModel", "init hydrate: read sortDirection=${sortDirection.name}")
                val readStatus = prefs.libraryFilterReadStatus.first()
                    .takeIf { it.isNotBlank() }
                    ?.let { runCatching { ReadStatus.valueOf(it) }.getOrNull() }
                android.util.Log.i("LibraryViewModel", "init hydrate: read readStatus=$readStatus")
                val downloadedOnly = prefs.libraryFilterDownloadedOnly.first()
                android.util.Log.i("LibraryViewModel", "init hydrate: read downloadedOnly=$downloadedOnly")
                val inProgressOnly = prefs.libraryFilterInProgressOnly.first()
                val completedOnly = prefs.libraryFilterCompletedOnly.first()
                val notStartedOnly = prefs.libraryFilterNotStartedOnly.first()
                android.util.Log.i("LibraryViewModel", "init hydrate: read progress filters")
                val excludedLibraryIds = prefs.excludedLibraryIds.first()
                val persistedLibrary = prefs.librarySelectedId.first()
                val selectedLibrary = persistedLibrary?.takeUnless { it in excludedLibraryIds }
                if (persistedLibrary != selectedLibrary) prefs.setLibrarySelectedId(null)
                android.util.Log.i("LibraryViewModel", "init hydrate: read selectedLibrary=$selectedLibrary")
                val layout = runCatching { LibraryLayout.valueOf(prefs.libraryLayout.first()) }
                    .getOrDefault(LibraryLayout.TWO_COLUMN)
                android.util.Log.i("LibraryViewModel", "init hydrate: read layout=${layout.name}")
                val mediaTypeRaw = prefs.mediaType.first()
                android.util.Log.i("LibraryViewModel", "init hydrate: read mediaTypeRaw=$mediaTypeRaw")
                val mediaType = runCatching {
                    when (AppMediaType.valueOf(mediaTypeRaw)) {
                        AppMediaType.PODCAST -> AppMediaType.AUDIOBOOK
                        else -> AppMediaType.valueOf(mediaTypeRaw)
                    }
                }.getOrDefault(AppMediaType.AUDIOBOOK)
                android.util.Log.i(
                    "LibraryViewModel",
                    "init hydrate: sortOption=${sortOption.name} secondary=${secondarySortOption?.name ?: "<none>"} dir=${sortDirection.name} layout=${layout.name} mediaType=${mediaType.name} downloadedOnly=$downloadedOnly inProgressOnly=$inProgressOnly completedOnly=$completedOnly notStartedOnly=$notStartedOnly selectedLib=$selectedLibrary",
                )
                _state.update {
                    it.copy(
                        sortOption = sortOption,
                        secondarySortOption = secondarySortOption,
                        sortDirection = sortDirection,
                        selectedFilter = readStatus,
                        showDownloadedOnly = downloadedOnly,
                        showInProgressOnly = inProgressOnly,
                        showCompletedOnly = completedOnly,
                        showNotStartedOnly = notStartedOnly,
                        selectedLibraryId = selectedLibrary,
                        layout = layout,
                        mediaType = mediaType,
                    )
                }
                android.util.Log.i("LibraryViewModel", "init hydrate: state updated")
            } catch (e: Throwable) {
                android.util.Log.e("LibraryViewModel", "Initial hydration failed; state remains at defaults", e)
            }
        }

        viewModelScope.launch {
            prefs.libraryHiddenBookIds.collect { ids ->
                if (_state.value.hiddenBookIds != ids) {
                    _state.update { it.copy(hiddenBookIds = ids) }
                }
            }
        }

        viewModelScope.launch {
            prefs.excludedLibraryIds.collect { ids ->
                val selectedLibrary = _state.value.selectedLibraryId
                val clearSelection = selectedLibrary != null && selectedLibrary in ids
                if (_state.value.excludedLibraryIds != ids || clearSelection) {
                    _state.update {
                        it.copy(
                            excludedLibraryIds = ids,
                            selectedLibraryId = if (clearSelection) null else it.selectedLibraryId,
                        )
                    }
                }
                if (clearSelection) prefs.setLibrarySelectedId(null)
            }
        }

        viewModelScope.launch {
            combine(
                prefs.titleDisplayMode,
                prefs.subtitleHandling,
                prefs.mergeAggressiveness,
                prefs.showAdvancedLibrarySettings,
                prefs.authorGroupingThreshold,
            ) { mode, subtitle, merge, advanced, threshold ->
                _state.update {
                    it.copy(
                        titleDisplayMode = mode,
                        subtitleHandling = subtitle,
                        mergeAggressiveness = merge,
                        showAdvancedLibrarySettings = advanced,
                        authorGroupingThreshold = threshold,
                    )
                }
            }.collect {}
        }

        viewModelScope.launch {
            prefs.bookCardStyle.collect { style ->
                if (_state.value.bookCardStyle != style) {
                    _state.update { it.copy(bookCardStyle = style) }
                }
            }
        }

        viewModelScope.launch {
            connectionRegistry.connections.collect { conns ->
                _state.update { it.copy(connections = conns.filter { c -> c.enabled }) }
                refreshLibraries()
            }
        }
    }

    private suspend fun refreshLibraries() {
        val merged = libraryListResolver.resolveAll()
        _state.update { it.copy(libraries = merged, isLoading = false) }
    }

    private val pagerInputs: Flow<PagerInputs> = combine(
        _state.map { it.selectedLibraryId }.distinctUntilChanged(),
        _state.map { it.searchQuery }.distinctUntilChanged().debounce(250),
        _state.map { it.sortOption to it.sortDirection }.distinctUntilChanged(),
        _state.map { it.selectedFilter }.distinctUntilChanged(),
        combine(
            _state.map { it.seriesFilter }.distinctUntilChanged(),
            _state.map { st -> st.connections.map { it.id }.sorted().joinToString(",") }.distinctUntilChanged(),
        ) { seriesFilter, connectionsKey -> seriesFilter to connectionsKey },
    ) { selectedLibId, search, sortPair, filterStatus, seriesAndConns ->
        val series = seriesAndConns.first?.takeIf { it.isNotBlank() }

        PagerInputs(
            selectedLibId = selectedLibId,
            search = search.takeIf { it.isNotBlank() },
            sort = sortKey(sortPair.first),
            dir = if (sortPair.second == SortDirection.ASCENDING) "asc" else "desc",
            status = if (series != null) null else filterStatus,
            seriesFilter = series,
            connectionsKey = seriesAndConns.second,
        )
    }

    private val allLibraryCacheBooks: Flow<List<Book>> = _state
        .map { it.excludedLibraryIds }
        .distinctUntilChanged()
        .flatMapLatest(libraryCacheRepository::rawAllBooksExcludingLibraries)

    private val allLibrariesBooks: Flow<PagingData<Book>> = combine(
        allLibraryCacheBooks,
        bookloreRepository.downloadedIds,

        _state.map {
            val inSeries = it.seriesFilter?.isNotBlank() == true
            AllLibrariesFilterConfig(
                mediaType = it.mediaType,
                downloadedOnly = it.showDownloadedOnly && !inSeries,
                inProgressOnly = it.showInProgressOnly && !inSeries,
                completedOnly = it.showCompletedOnly && !inSeries,
                notStartedOnly = it.showNotStartedOnly && !inSeries,
                hiddenIds = it.hiddenBookIds,
                excludedLibraryIds = it.excludedLibraryIds,
                seriesFilter = it.seriesFilter?.takeIf { name -> name.isNotBlank() },
                authorFilter = it.authorFilter?.takeIf { name -> name.isNotBlank() },
                genreFilter = it.genreFilter?.takeIf { name -> name.isNotBlank() },
            )
        }.distinctUntilChanged(),

        _state.map { it.searchQuery }.distinctUntilChanged().debounce(250),
        _state.map {
            SortConfig(
                primary = it.sortOption,
                secondary = it.secondarySortOption,
                direction = it.sortDirection,
            )
        }.distinctUntilChanged(),
    ) { books, downloaded, filter, search, sort ->
        val needle = search.trim().lowercase().takeIf { it.isNotEmpty() }
        val filteredList = books
            .visibleLibraryBooks(filter.excludedLibraryIds)
            .asSequence()
            .map { book -> book.copy(isDownloaded = book.id in downloaded) }
            .filter { book ->
                if (book.id in filter.hiddenIds) return@filter false
                if (book.mediaType != filter.mediaType) return@filter false
                if (filter.downloadedOnly && !book.isDownloaded) return@filter false
                if (filter.inProgressOnly && !(book.readProgress in 0.001f..0.999f)) return@filter false
                if (filter.completedOnly && !book.isFinished) return@filter false
                if (filter.notStartedOnly && (book.readProgress > 0f || book.isFinished)) return@filter false
                if (filter.seriesFilter != null && book.seriesName != filter.seriesFilter) return@filter false
                if (filter.authorFilter != null && !book.matchesAuthorFilter(filter.authorFilter)) return@filter false
                if (filter.genreFilter != null && !book.matchesGenreFilter(filter.genreFilter)) return@filter false
                if (needle != null) {
                    val title = book.title.lowercase()
                    val author = book.author?.lowercase().orEmpty()
                    val series = book.seriesName?.lowercase().orEmpty()
                    val narrator = book.narrator?.lowercase().orEmpty()
                    if (!title.contains(needle) &&
                        !author.contains(needle) &&
                        !series.contains(needle) &&
                        !narrator.contains(needle)
                    ) return@filter false
                }
                true
            }
            .toList()

        val sorted = filteredList.sortedWith(comparatorForSort(sort))
        _state.update { it.copy(totalBookCount = sorted.size) }
        android.util.Log.i(
            "LibraryViewModel",
            "allLibrariesBooks: input=${books.size} mediaType=${filter.mediaType} downloadedOnly=${filter.downloadedOnly} sort=${sort.primary.name}/${sort.direction.name} search='${needle ?: ""}' filtered=${sorted.size}",
        )

        PagingData.from(
            data = sorted,
            sourceLoadStates = LoadStates(
                refresh = LoadState.NotLoading(endOfPaginationReached = true),
                prepend = LoadState.NotLoading(endOfPaginationReached = true),
                append = LoadState.NotLoading(endOfPaginationReached = true),
            ),
        )
    }

    private val singleLibraryBooks: Flow<PagingData<Book>> = pagerInputs
        .flatMapLatest { inputs -> pagerForInputs(inputs).flow }
        .cachedIn(viewModelScope)

    val books: Flow<PagingData<Book>> = _state.map { it.selectedLibraryId }
        .distinctUntilChanged()
        .flatMapLatest { selectedLibId ->
            if (selectedLibId == null) {
                allLibrariesBooks
            } else {
                combine(
                    singleLibraryBooks,
                    bookloreRepository.downloadedIds,
                    _state.map {
                        val inSeries = it.seriesFilter?.isNotBlank() == true
                        it.mediaType to (it.showDownloadedOnly && !inSeries)
                    }.distinctUntilChanged(),
                    _state.map {
                        val inSeries = it.seriesFilter?.isNotBlank() == true
                        InProgressFilter(
                            inProgressOnly = it.showInProgressOnly && !inSeries,
                            completedOnly = it.showCompletedOnly && !inSeries,
                            notStartedOnly = it.showNotStartedOnly && !inSeries,
                            hiddenIds = it.hiddenBookIds,
                            excludedLibraryIds = it.excludedLibraryIds,
                            authorFilter = it.authorFilter?.takeIf { name -> name.isNotBlank() },
                            genreFilter = it.genreFilter?.takeIf { name -> name.isNotBlank() },
                        )
                    }.distinctUntilChanged(),
                ) { pagingData, downloaded, mediaPair, prog ->
                    pagingData
                        .map { book -> book.copy(isDownloaded = book.id in downloaded) }
                        .filter { book ->
                            if (book.id in prog.hiddenIds) return@filter false
                            if (book.libraryId != null && book.libraryId in prog.excludedLibraryIds) return@filter false
                            if (book.mediaType != mediaPair.first) return@filter false
                            if (mediaPair.second && !book.isDownloaded) return@filter false
                            if (prog.inProgressOnly && !(book.readProgress in 0.001f..0.999f)) return@filter false
                            if (prog.completedOnly && !book.isFinished) return@filter false
                            if (prog.notStartedOnly && (book.readProgress > 0f || book.isFinished)) return@filter false
                            if (prog.authorFilter != null && !book.matchesAuthorFilter(prog.authorFilter)) return@filter false
                            if (prog.genreFilter != null && !book.matchesGenreFilter(prog.genreFilter)) return@filter false
                            true
                        }
                }
            }
        }

    private fun pagerForInputs(inputs: PagerInputs): Pager<Int, Book> {

        val resolved = resolveSelection(inputs.selectedLibId)
        return Pager(
            config = PagingConfig(
                pageSize = 50,
                initialLoadSize = 100,
                prefetchDistance = 10,
                enablePlaceholders = false,
            ),
        ) {
            when (resolved?.source) {
                BookSource.GRIMMORY -> bookloreBooksSource(resolved, inputs)
                BookSource.KOMGA -> komgaBooksSource(resolved, inputs)
                BookSource.AUDIOBOOKSHELF -> absBooksSource(resolved, inputs)
                BookSource.BOOKORBIT -> bookOrbitBooksSource(resolved)
                BookSource.OPDS -> opdsBooksSource(resolved, inputs)
                BookSource.STORYTELLER -> storytellerBooksSource(resolved, inputs)
                else -> if (resolved == null) emptySource() else legacyAggregatorSource(resolved, inputs)
            }
        }
    }

    private fun bookOrbitBooksSource(resolved: ResolvedSelection): PagingSource<Int, Book> {
        val rawId = resolved.compositeLibraryId?.substringAfter("::", missingDelimiterValue = resolved.compositeLibraryId)
            ?.takeIf { it.isNotBlank() }
        return BookOrbitBooksPagingSource(
            repository = bookOrbitRepository,
            params = BookOrbitBooksPagingSource.Params(
                connectionId = resolved.connectionId,
                libraryId = rawId,
            ),
        )
    }

    private fun opdsBooksSource(resolved: ResolvedSelection, inputs: PagerInputs): PagingSource<Int, Book> {
        val inner = OpdsBooksPagingSource(
            opdsRepository,
            OpdsBooksPagingSource.Params(
                connectionId = resolved.connectionId,
                onTotalCountChanged = { count -> _state.update { it.copy(totalBookCount = count) } },
            ),
        )
        return SummaryToBookSource(
            inner = { inner },
            isDownloaded = { id -> bookloreRepository.isDownloaded(id) },
            onTotalCountChanged = null,
        )
    }

    private fun komgaBooksSource(resolved: ResolvedSelection, inputs: PagerInputs): PagingSource<Int, Book> {
        val rawId = resolved.compositeLibraryId?.substringAfter("::", missingDelimiterValue = "")
            ?.takeIf { it.isNotBlank() }
        val params = KomgaBooksPagingSource.Params(
            connectionId = resolved.connectionId,
            libraryId = rawId,
            sort = komgaSortKey(inputs.sort),
            dir = inputs.dir,
            search = inputs.search,
            readStatus = inputs.status?.let { listOf(it.name) },
        )

        val inner = KomgaBooksPagingSource(
            repo = komgaRepository,
            connectionRegistry = connectionRegistry,
            params = params,
            onTotalCount = { count -> _state.update { it.copy(totalBookCount = count) } },
        )
        return SummaryToBookSource(
            inner = { inner },
            isDownloaded = { id -> bookloreRepository.isDownloaded(id) },

            onTotalCountChanged = null,
        )
    }

    private fun absBooksSource(resolved: ResolvedSelection, inputs: PagerInputs): PagingSource<Int, Book> {
        val rawId = resolved.compositeLibraryId?.substringAfter("::", missingDelimiterValue = "")
            ?.takeIf { it.isNotBlank() }
            ?: return emptySource()
        val params = AudiobookshelfBooksPagingSource.Params(
            connectionId = resolved.connectionId,
            libraryId = rawId,
            sort = absSortKey(inputs.sort),
            dir = inputs.dir,
        )

        val inner = AudiobookshelfBooksPagingSource(
            repo = absRepository,
            params = params,
            onTotalCount = { count -> _state.update { it.copy(totalBookCount = count) } },
        )
        return SummaryToBookSource(
            inner = { inner },
            isDownloaded = { id -> bookloreRepository.isDownloaded(id) },
            onTotalCountChanged = null,
        )
    }

    private fun komgaSortKey(unified: String): String = when (unified) {
        "title" -> "metadata.title"
        "addedOn" -> "createdDate"
        "authors" -> "metadata.authors"
        "seriesNumber" -> "metadata.numberSort"
        else -> "metadata.title"
    }

    private fun absSortKey(unified: String): String = when (unified) {
        "title" -> "media.metadata.title"
        "addedOn" -> "addedAt"
        "authors" -> "media.metadata.authorName"
        "duration" -> "media.duration"
        else -> "media.metadata.title"
    }

    private fun bookloreBooksSource(resolved: ResolvedSelection, inputs: PagerInputs): PagingSource<Int, Book> {
        val params = GrimmoryBooksPagingSource.Params(
            connectionId = resolved.connectionId,
            libraryId = resolved.bookloreLibraryId,
            sort = inputs.sort,
            dir = inputs.dir,
            status = inputs.status,
            search = inputs.search,
        )
        val source = GrimmoryBooksPagingSource(bookloreRepository, params)

        return WrappedBookloreSource(
            inner = source,
            connectionId = resolved.connectionId,
            isDownloaded = { id -> bookloreRepository.isDownloaded(id) },
            seriesFilter = inputs.seriesFilter,
            bookloreRepository = bookloreRepository,
            params = params,
            onTotalCountChanged = { count ->
                _state.update { it.copy(totalBookCount = count) }
            },
        )
    }

    private fun storytellerBooksSource(resolved: ResolvedSelection, inputs: PagerInputs): PagingSource<Int, Book> {
        return object : PagingSource<Int, Book>() {
            override suspend fun load(params: LoadParams<Int>): LoadResult<Int, Book> {
                if (params.key != null && params.key != 0) {
                    return LoadResult.Page(emptyList(), null, null)
                }
                val result = withContext(ConnectionScope.asContextElement(resolved.connectionId)) {
                    if (inputs.seriesFilter != null) {
                        storytellerRepository.getSeriesBooks(inputs.seriesFilter)
                    } else {
                        storytellerRepository.getBooks()
                    }
                }
                return result.fold(
                    onSuccess = { books ->
                        _state.update { it.copy(totalBookCount = books.size) }
                        LoadResult.Page(books, prevKey = null, nextKey = null)
                    },
                    onFailure = { LoadResult.Error(it) },
                )
            }
            override fun getRefreshKey(state: PagingState<Int, Book>): Int? = 0
        }
    }

    private fun legacyAggregatorSource(resolved: ResolvedSelection, inputs: PagerInputs): PagingSource<Int, Book> {
        return object : PagingSource<Int, Book>() {
            override suspend fun load(params: LoadParams<Int>): LoadResult<Int, Book> {
                if (params.key != null && params.key != 0) {
                    return LoadResult.Page(emptyList(), null, null)
                }
                return aggregatorRepository.getBooks(
                    libraryId = resolved.compositeLibraryId,
                    page = 0,
                    size = 1000,
                ).fold(
                    onSuccess = { books ->
                        _state.update { it.copy(totalBookCount = books.size) }
                        LoadResult.Page(books, prevKey = null, nextKey = null)
                    },
                    onFailure = { LoadResult.Error(it) },
                )
            }
            override fun getRefreshKey(state: PagingState<Int, Book>): Int? = 0
        }
    }

    private fun emptySource(): PagingSource<Int, Book> = object : PagingSource<Int, Book>() {
        override suspend fun load(params: LoadParams<Int>): LoadResult<Int, Book> {
            _state.update { it.copy(totalBookCount = 0) }
            return LoadResult.Page(emptyList(), null, null)
        }
        override fun getRefreshKey(state: PagingState<Int, Book>): Int? = null
    }

    private data class ResolvedSelection(
        val connectionId: String,
        val source: BookSource,
        val bookloreLibraryId: Long? = null,
        val compositeLibraryId: String? = null,
    )

    private fun resolveSelection(selectedLibId: String?): ResolvedSelection? {
        val libraries = _state.value.libraries
        if (selectedLibId != null) {
            if (selectedLibId in _state.value.excludedLibraryIds) return null
            val match = libraries.find { it.id == selectedLibId } ?: return null
            val rawId = match.id.substringAfter("::", missingDelimiterValue = match.id)
            return ResolvedSelection(
                connectionId = match.connectionId ?: return null,
                source = match.source,
                bookloreLibraryId = if (match.source == BookSource.GRIMMORY) rawId.toLongOrNull() else null,
                compositeLibraryId = if (match.source != BookSource.GRIMMORY) match.id else null,
            )
        }

        val conns = runCatching { connectionRegistry.getConnectionsSync().filter { it.enabled } }.getOrDefault(emptyList())
        val bookloore = conns.firstOrNull { it.source == BookSource.GRIMMORY }
        if (bookloore != null) {
            return ResolvedSelection(
                connectionId = bookloore.id,
                source = BookSource.GRIMMORY,
                bookloreLibraryId = null,
            )
        }
        val other = conns.firstOrNull() ?: return null
        return ResolvedSelection(
            connectionId = other.id,
            source = other.source,
            compositeLibraryId = null,
        )
    }

    private fun sortKey(option: SortOption): String = when (option) {
        SortOption.TITLE -> "title"
        SortOption.AUTHOR, SortOption.AUTHOR_SURNAME -> "authors"
        SortOption.DATE_ADDED -> "addedOn"
        SortOption.NARRATOR -> "narrator"
        SortOption.PROGRESS -> "readProgress"
        SortOption.DURATION -> "duration"
        SortOption.PUBLISHED_YEAR -> "publishedDate"
        SortOption.SERIES_ORDER -> "seriesNumber"
    }

    fun loadBooks() {

        viewModelScope.launch { refreshLibraries() }
    }

    fun refresh() {
        viewModelScope.launch {
            _state.update { it.copy(isRefreshing = true) }

            bookloreRepository.invalidateAllCaches()
            aggregatorRepository.invalidateCaches()
            refreshLibraries()

            _state.update { it.copy(searchQuery = it.searchQuery, isRefreshing = false) }
        }
    }

    suspend fun refreshCachedMetadata(): Int =
        libraryCacheRepository.enrichAudiobookNarratorsNow()

    suspend fun checkAllConnectionsHealth(): Map<String, Boolean> =
        aggregatorRepository.checkAllConnectionsHealth()

    suspend fun refreshProviderMetadata(): LibraryMetadataRefreshSummary {
        val libraries = _state.value.libraries
        if (libraries.isEmpty()) {
            return LibraryMetadataRefreshSummary(queued = 0, unsupported = 0, failed = emptyList())
        }
        _state.update { it.copy(isRefreshing = true) }
        return try {
            val summary = libraryMetadataRefreshRepository.refresh(libraries)
            refreshLibraries()
            summary
        } finally {
            _state.update { it.copy(isRefreshing = false) }
        }
    }

    fun setSearchQuery(query: String) {
        _state.update { it.copy(searchQuery = query) }
    }

    fun setSortOption(option: SortOption) {
        android.util.Log.i("LibraryViewModel", "setSortOption: persisting ${option.name}")
        _state.update { it.copy(sortOption = option) }
        viewModelScope.launch { prefs.setLibrarySortOption(option.name) }
    }

    fun setSecondarySortOption(option: SortOption?) {
        android.util.Log.i("LibraryViewModel", "setSecondarySortOption: persisting ${option?.name ?: "<none>"}")
        _state.update { it.copy(secondarySortOption = option) }
        viewModelScope.launch { prefs.setLibrarySortSecondary(option?.name) }
    }

    fun setSortDirection(direction: SortDirection) {
        android.util.Log.i("LibraryViewModel", "setSortDirection: persisting ${direction.name}")
        _state.update { it.copy(sortDirection = direction) }
        viewModelScope.launch { prefs.setLibrarySortDirection(direction.name) }
    }

    fun toggleSortDirection() {
        val newDirection = if (_state.value.sortDirection == SortDirection.ASCENDING)
            SortDirection.DESCENDING else SortDirection.ASCENDING
        setSortDirection(newDirection)
    }

    fun setLayout(layout: LibraryLayout) {
        viewModelScope.launch { prefs.setLibraryLayout(layout.name) }
        _state.update { it.copy(layout = layout) }
    }

    fun setMediaType(type: AppMediaType) {
        val safeType = if (type == AppMediaType.PODCAST) AppMediaType.AUDIOBOOK else type
        viewModelScope.launch { prefs.setMediaType(safeType.name) }
        _state.update { it.copy(mediaType = safeType, seriesFilter = null) }
    }

    fun setFilter(status: ReadStatus?) {
        _state.update { it.copy(selectedFilter = status) }
        viewModelScope.launch { prefs.setLibraryFilterReadStatus(status?.name) }
    }

    fun setShowDownloadedOnly(value: Boolean) {
        _state.update { it.copy(showDownloadedOnly = value) }
        viewModelScope.launch { prefs.setLibraryFilterDownloadedOnly(value) }
    }

    fun setShowInProgressOnly(value: Boolean) {
        _state.update { it.copy(showInProgressOnly = value) }
        viewModelScope.launch { prefs.setLibraryFilterInProgressOnly(value) }
    }

    fun setShowCompletedOnly(value: Boolean) {
        _state.update { it.copy(showCompletedOnly = value) }
        viewModelScope.launch { prefs.setLibraryFilterCompletedOnly(value) }
    }

    fun setShowNotStartedOnly(value: Boolean) {
        _state.update { it.copy(showNotStartedOnly = value) }
        viewModelScope.launch { prefs.setLibraryFilterNotStartedOnly(value) }
    }

    fun setSeriesFilter(name: String?) {
        if (_state.value.seriesFilter == name) return
        _state.update { it.copy(seriesFilter = name) }
    }

    fun setAuthorFilter(name: String?) {
        if (_state.value.authorFilter == name) return
        _state.update { it.copy(authorFilter = name) }
    }

    fun setGenreFilter(name: String?) {
        if (_state.value.genreFilter == name) return
        _state.update { it.copy(genreFilter = name) }
    }

    fun toggleLibraryExclusion(libraryId: String) {
        val current = _state.value.excludedLibraryIds
        val updated = if (current.contains(libraryId)) current - libraryId else current + libraryId
        val clearSelection = libraryId in updated && _state.value.selectedLibraryId == libraryId
        _state.update {
            it.copy(
                excludedLibraryIds = updated,
                selectedLibraryId = if (clearSelection) null else it.selectedLibraryId,
            )
        }
        viewModelScope.launch {
            prefs.setExcludedLibraryIds(updated)
            if (clearSelection) prefs.setLibrarySelectedId(null)
        }
    }

    fun isLibraryExcluded(libraryId: String): Boolean =
        _state.value.excludedLibraryIds.contains(libraryId)

    fun setBookCardStyle(style: BookCardStyle) {
        _state.update { it.copy(bookCardStyle = style) }
        viewModelScope.launch { prefs.setBookCardStyle(style) }
    }

    fun setTitleDisplayMode(mode: TitleDisplayMode) {
        _state.update { it.copy(titleDisplayMode = mode) }
        viewModelScope.launch { prefs.setTitleDisplayMode(mode) }
    }

    fun setSubtitleHandling(handling: SubtitleHandling) {
        _state.update { it.copy(subtitleHandling = handling) }
        viewModelScope.launch { prefs.setSubtitleHandling(handling) }
    }

    fun setMergeAggressiveness(aggressiveness: MergeAggressiveness) {
        _state.update { it.copy(mergeAggressiveness = aggressiveness) }
        viewModelScope.launch { prefs.setMergeAggressiveness(aggressiveness) }
    }

    fun setShowAdvancedLibrarySettings(value: Boolean) {
        _state.update { it.copy(showAdvancedLibrarySettings = value) }
        viewModelScope.launch { prefs.setShowAdvancedLibrarySettings(value) }
    }

    fun setAuthorGroupingThreshold(value: Float) {
        _state.update { it.copy(authorGroupingThreshold = value) }
        viewModelScope.launch { prefs.setAuthorGroupingThreshold(value) }
    }

    fun forceLibraryCacheRebuild() {
        viewModelScope.launch {
            _state.update { it.copy(isRefreshing = true, error = null) }
            try {
                bookloreRepository.invalidateAllCaches()
                aggregatorRepository.invalidateCaches()
                libraryCacheRepository.invalidateAndRefresh()
                refreshLibraries()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Couldn't rebuild library cache") }
            } finally {
                _state.update { it.copy(isRefreshing = false) }
            }
        }
    }

    fun clearAllFilters() {
        _state.update {
            it.copy(
                sortOption = SortOption.DATE_ADDED,
                secondarySortOption = null,
                sortDirection = SortDirection.DESCENDING,
                selectedFilter = null,
                showDownloadedOnly = false,
                showInProgressOnly = false,
                showCompletedOnly = false,
                showNotStartedOnly = false,
                authorFilter = null,
                genreFilter = null,
            )
        }
        viewModelScope.launch { prefs.clearLibraryFilters() }
    }

    fun toggleSelectionMode() {
        _state.update {
            if (it.isSelectionMode) it.copy(isSelectionMode = false, selectedBookIds = emptySet())
            else it.copy(isSelectionMode = true, selectedBookIds = emptySet())
        }
    }

    fun toggleBookSelection(book: Book) {
        _state.update {
            val newIds = it.selectedBookIds.toMutableSet()
            if (newIds.contains(book.id)) newIds.remove(book.id) else newIds.add(book.id)
            it.copy(selectedBookIds = newIds)
        }
    }

    fun selectAll(visibleIds: Collection<String>) {
        _state.update { it.copy(selectedBookIds = visibleIds.toSet()) }
    }

    fun deselectAll() {
        _state.update { it.copy(selectedBookIds = emptySet()) }
    }

    fun isBookSelected(book: Book): Boolean = _state.value.selectedBookIds.contains(book.id)

    fun hideSelectedBooks() {
        val selected = _state.value.selectedBookIds
        if (selected.isEmpty()) return
        val newHidden = _state.value.hiddenBookIds + selected
        _state.update {
            it.copy(
                hiddenBookIds = newHidden,
                selectedBookIds = emptySet(),
                isSelectionMode = false,
            )
        }
        viewModelScope.launch { prefs.setLibraryHiddenBookIds(newHidden) }
    }

    fun deleteSelectedBooks(visibleBooks: List<Book>) {
        val selected = _state.value.selectedBookIds
        if (selected.isEmpty()) return

        val selectedBooks = visibleBooks.filter { it.id in selected }
        val localBooks = selectedBooks.filter { it.source == BookSource.LOCAL }
        val remoteIds = selected - localBooks.mapTo(mutableSetOf()) { it.id }

        _state.update {
            it.copy(
                selectedBookIds = emptySet(),
                isSelectionMode = false,
                hiddenBookIds = it.hiddenBookIds + remoteIds,
            )
        }

        viewModelScope.launch {
            if (remoteIds.isNotEmpty()) {
                prefs.setLibraryHiddenBookIds(_state.value.hiddenBookIds)
            }
            localBooks.forEach { book ->
                offlineDownloadManager.removeDownload(book.id)
                comicOfflineService.removeDownload(book.id)
                aggregatorRepository.deleteBook(book)
            }
        }
    }

    fun downloadVisible(books: List<Book>) {
        if (books.isEmpty()) return
        val (audio, comics) = books.partition {
            it.mediaType == AppMediaType.AUDIOBOOK &&
                offlineDownloadManager.supportsAudiobookDownload(it.source)
        }
        audio.forEach { offlineDownloadManager.startAudiobookDownload(it) }
        if (comics.isNotEmpty()) comicOfflineService.startDownloadAll(comics)
        _state.update { it.copy(isSelectionMode = false, selectedBookIds = emptySet()) }
    }

    fun removeDownloadsFromSelected() {
        val ids = _state.value.selectedBookIds
        if (ids.isEmpty()) return
        ids.forEach {
            offlineDownloadManager.removeDownload(it)
            comicOfflineService.removeDownload(it)
        }
        _state.update { it.copy(isSelectionMode = false, selectedBookIds = emptySet()) }
    }

    fun unhideBooks(ids: Collection<String>) {
        if (ids.isEmpty()) return
        val newHidden = _state.value.hiddenBookIds - ids.toSet()
        _state.update { it.copy(hiddenBookIds = newHidden) }
        viewModelScope.launch { prefs.setLibraryHiddenBookIds(newHidden) }
    }

    fun clearHiddenBooks() {
        if (_state.value.hiddenBookIds.isEmpty()) return
        _state.update { it.copy(hiddenBookIds = emptySet()) }
        viewModelScope.launch { prefs.setLibraryHiddenBookIds(emptySet()) }
    }

    fun setSelectedLibrary(libraryId: String?) {
        val visibleLibraryId = libraryId?.takeUnless { it in _state.value.excludedLibraryIds }
        _state.update { it.copy(selectedLibraryId = visibleLibraryId) }
        viewModelScope.launch { prefs.setLibrarySelectedId(visibleLibraryId) }
    }

    private data class PagerInputs(
        val selectedLibId: String?,
        val search: String?,
        val sort: String,
        val dir: String,
        val status: ReadStatus?,
        val seriesFilter: String?,

        val connectionsKey: String,
    )

    private data class InProgressFilter(
        val inProgressOnly: Boolean,
        val completedOnly: Boolean,
        val notStartedOnly: Boolean,
        val hiddenIds: Set<String>,
        val excludedLibraryIds: Set<String>,
        val authorFilter: String?,
        val genreFilter: String?,
    )

    private data class AllLibrariesFilterConfig(
        val mediaType: AppMediaType,
        val downloadedOnly: Boolean,
        val inProgressOnly: Boolean,
        val completedOnly: Boolean,
        val notStartedOnly: Boolean,
        val hiddenIds: Set<String>,
        val excludedLibraryIds: Set<String>,
        val seriesFilter: String?,
        val authorFilter: String?,
        val genreFilter: String?,
    )

    private data class SortConfig(
        val primary: SortOption,
        val secondary: SortOption?,
        val direction: SortDirection,
    )

    private fun Book.matchesAuthorFilter(rawAuthor: String): Boolean {
        val target = rawAuthor.normalizedMetadataToken()
        val authorText = author?.takeIf { it.isNotBlank() } ?: return false
        if (authorText.normalizedMetadataToken() == target) return true
        return authorText
            .split(',', ';', '&')
            .map { it.trim() }
            .any { it.normalizedMetadataToken() == target }
    }

    private fun Book.matchesGenreFilter(rawGenre: String): Boolean {
        val target = rawGenre.normalizedMetadataToken()
        return categories.any { it.normalizedMetadataToken() == target }
    }

    private fun String.normalizedMetadataToken(): String =
        trim().lowercase(Locale.US)

    private fun comparatorForSort(config: SortConfig): Comparator<Book> {
        val primary = comparatorFor(config.primary)
        val combined = config.secondary?.let { sec -> primary.then(comparatorFor(sec)) } ?: primary
        return if (config.direction == SortDirection.ASCENDING) combined else combined.reversed()
    }

    private fun comparatorFor(option: SortOption): Comparator<Book> {
        return when (option) {
            SortOption.TITLE -> Comparator { a, b -> NaturalSort.compare(a.title, b.title) }
            SortOption.AUTHOR -> Comparator { a, b ->
                NaturalSort.compare(a.author?.trim(), b.author?.trim())
            }
            SortOption.AUTHOR_SURNAME -> Comparator { a, b ->
                fun surname(book: Book) =
                    book.author?.split(',')?.firstOrNull()?.trim()?.split(' ')?.lastOrNull()
                NaturalSort.compare(surname(a), surname(b))
            }
            SortOption.NARRATOR -> Comparator { a, b ->
                NaturalSort.compare(a.narrator?.trim(), b.narrator?.trim())
            }
            SortOption.DATE_ADDED -> compareBy { it.addedOn }
            SortOption.PROGRESS -> compareBy { it.readProgress }
            SortOption.DURATION -> compareBy { it.duration }
            SortOption.PUBLISHED_YEAR -> Comparator { a, b ->
                NaturalSort.compare(a.publishedDate, b.publishedDate)
            }
            SortOption.SERIES_ORDER -> {

                val floatNullsLast: Comparator<Float?> = nullsLast(naturalOrder())
                Comparator { a, b ->
                    val seriesCmp = NaturalSort.compare(a.seriesName, b.seriesName)
                    if (seriesCmp != 0) return@Comparator seriesCmp
                    fun seriesFloat(book: Book): Float? =
                        book.seriesNumber?.takeWhile { it.isDigit() || it == '.' }?.toFloatOrNull()
                    val numCmp = floatNullsLast.compare(seriesFloat(a), seriesFloat(b))
                    if (numCmp != 0) return@Comparator numCmp
                    val rawCmp = NaturalSort.compare(a.seriesNumber, b.seriesNumber)
                    if (rawCmp != 0) return@Comparator rawCmp
                    NaturalSort.compare(a.title, b.title)
                }
            }
        }
    }
}

private class SummaryToBookSource(
    private val inner: () -> PagingSource<Int, com.enve.core.data.model.BookSummary>,
    private val isDownloaded: (String) -> Boolean,
    private val onTotalCountChanged: ((Int) -> Unit)?,
) : PagingSource<Int, Book>() {

    private val delegate = inner()

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, Book> {
        val result = delegate.load(params)
        return when (result) {
            is LoadResult.Page -> {
                val page = (params.key ?: 0)
                if (page == 0 && onTotalCountChanged != null) {
                    val approximateTotal = result.data.size +
                        ((result.nextKey ?: 0) * params.loadSize)
                    onTotalCountChanged.invoke(approximateTotal.coerceAtLeast(result.data.size))
                }
                LoadResult.Page(
                    data = result.data.map { it.toShallowBook(isDownloaded(it.id)) },
                    prevKey = result.prevKey,
                    nextKey = result.nextKey,
                )
            }
            is LoadResult.Error -> LoadResult.Error(result.throwable)
            is LoadResult.Invalid -> LoadResult.Invalid()
        }
    }

    override fun getRefreshKey(state: PagingState<Int, Book>): Int? = null
}

private class WrappedBookloreSource(
    private val inner: GrimmoryBooksPagingSource,
    private val connectionId: String,
    private val isDownloaded: (String) -> Boolean,
    private val seriesFilter: String?,
    private val bookloreRepository: GrimmoryAppRepository,
    private val params: GrimmoryBooksPagingSource.Params,
    private val onTotalCountChanged: (Int) -> Unit,
) : PagingSource<Int, Book>() {

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, Book> {
        val page = params.key ?: 0

        if (seriesFilter != null) {
            return bookloreRepository.getSeriesBooks(
                connectionId = connectionId,
                seriesName = seriesFilter,
                page = page,
                size = params.loadSize,
                libraryId = this.params.libraryId,
            ).fold(
                onSuccess = { result ->
                    if (page == 0) onTotalCountChanged(result.totalElements.toInt())
                    LoadResult.Page(
                        data = result.items.map { it.toShallowBook(isDownloaded(it.id)) },
                        prevKey = if (page == 0) null else page - 1,
                        nextKey = if (result.hasNext) page + 1 else null,
                    )
                },
                onFailure = { LoadResult.Error(it) },
            )
        }
        return bookloreRepository.getBooksPage(
            connectionId = connectionId,
            libraryId = this.params.libraryId,
            shelfId = this.params.shelfId,
            page = page,
            size = params.loadSize,
            sort = this.params.sort,
            dir = this.params.dir,
            status = this.params.status,
            search = this.params.search,
            authors = this.params.authors,
            language = this.params.language,
            minRating = this.params.minRating,
            maxRating = this.params.maxRating,
        ).fold(
            onSuccess = { result ->
                if (page == 0) onTotalCountChanged(result.totalElements.toInt())
                LoadResult.Page(
                    data = result.items.map { it.toShallowBook(isDownloaded(it.id)) },
                    prevKey = if (page == 0) null else page - 1,
                    nextKey = if (result.hasNext) page + 1 else null,
                )
            },
            onFailure = { LoadResult.Error(it) },
        )
    }

    override fun getRefreshKey(state: PagingState<Int, Book>): Int? {
        return state.anchorPosition?.let { anchor ->
            val closest = state.closestPageToPosition(anchor) ?: return null
            closest.prevKey?.plus(1) ?: closest.nextKey?.minus(1)
        }
    }
}
