package com.enve.hearth.library

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookCardStyle
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.BrowseGroup
import com.enve.core.data.model.ComicSection
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.ReadStatus
import com.enve.core.data.model.isComic
import com.enve.core.data.util.FINISHED_PROGRESS_THRESHOLD
import com.enve.hearth.hasPlayableAudio
import com.enve.hearth.includesLibraryBook
import com.enve.engine.library.LibraryFacade
import com.enve.engine.library.SavedBookList
import com.enve.engine.library.SavedBooksFacade
import com.enve.engine.library.BookOrbitCollectionEdit
import com.enve.engine.library.LibraryConnectionOption
import com.enve.engine.playback.PlaybackFacade
import com.enve.engine.prefs.PreferencesFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.text.Normalizer
import java.util.Base64
import java.util.Locale
import javax.inject.Inject

enum class LibraryFacet { BOOKS, SERIES, AUTHORS, NARRATORS, SHELVES }
enum class DrillKind { SERIES, AUTHOR, NARRATOR, SHELF }
enum class StatusFilter(val label: String) {
    ALL("All"),
    CURRENTLY_READING("Currently reading"),
    UNREAD("Unread"),
    FINISHED("Read"),
    LISTENING("Listening"),
    READING("Reading ebooks"),
    DOWNLOADED("Downloaded"),
}
enum class MediaFilter(val label: String) { ALL("All media"), AUDIOBOOKS("Audiobooks"), EBOOKS("Ebooks"), COMICS("Comics") }
enum class SeriesFilter(val label: String) { ALL("Any"), IN_SERIES("In a series"), STANDALONE("Standalone") }

data class LibraryAdvancedFilters(
    val genres: Set<String> = emptySet(),
    val languages: Set<String> = emptySet(),
    val minimumRating: Float? = null,
    val series: SeriesFilter = SeriesFilter.ALL,
) {
    val isActive: Boolean
        get() = genres.isNotEmpty() || languages.isNotEmpty() || minimumRating != null || series != SeriesFilter.ALL
}

data class LibraryAdvancedFilterOptions(
    val genres: List<String> = emptyList(),
    val languages: List<String> = emptyList(),
)

internal object LibraryAdvancedFilterPolicy {
    private val combiningMarks = "\\p{Mn}+".toRegex()

    fun matches(book: Book, filters: LibraryAdvancedFilters): Boolean {
        if (filters.genres.isNotEmpty()) {
            val selected = filters.genres.mapTo(mutableSetOf(), ::normalized)
            val bookGenres = book.categories.mapTo(mutableSetOf(), ::normalized)
            if (selected.intersect(bookGenres).isEmpty()) return false
        }
        if (filters.languages.isNotEmpty()) {
            val selected = filters.languages.mapTo(mutableSetOf(), ::normalized)
            val language = book.language?.let(::normalized) ?: return false
            if (language !in selected) return false
        }
        filters.minimumRating?.let { minimum ->
            val rating = maxOf(book.personalRating ?: 0f, book.goodreadsRating ?: 0f)
            if (rating < minimum) return false
        }
        val hasSeries = !book.seriesName.isNullOrBlank()
        when (filters.series) {
            SeriesFilter.ALL -> Unit
            SeriesFilter.IN_SERIES -> if (!hasSeries) return false
            SeriesFilter.STANDALONE -> if (hasSeries) return false
        }
        return true
    }

    fun options(books: List<Book>): LibraryAdvancedFilterOptions = LibraryAdvancedFilterOptions(
        genres = uniqueSorted(books.flatMap(Book::categories)),
        languages = uniqueSorted(books.mapNotNull(Book::language)),
    )

    private fun uniqueSorted(values: List<String>): List<String> {
        val seen = mutableSetOf<String>()
        return values.asSequence()
            .map(String::trim)
            .filter(String::isNotEmpty)
            .filter { seen.add(normalized(it)) }
            .sortedWith(String.CASE_INSENSITIVE_ORDER)
            .toList()
    }

    private fun normalized(value: String): String =
        Normalizer.normalize(value.trim(), Normalizer.Form.NFD)
            .replace(combiningMarks, "")
            .lowercase(Locale.ROOT)
}

enum class SortDirection(val label: String, val arrow: String) {
    ASCENDING("Ascending", "↑"),
    DESCENDING("Descending", "↓"),
}

enum class LibrarySort(val label: String, val defaultDirection: SortDirection) {
    RECENT("Recent", SortDirection.DESCENDING),
    TITLE("Title", SortDirection.ASCENDING),
    AUTHOR("Author given", SortDirection.ASCENDING),
    AUTHOR_SURNAME("Author surname", SortDirection.ASCENDING),
    NARRATOR("Narrator given", SortDirection.ASCENDING),
    NARRATOR_SURNAME("Narrator surname", SortDirection.ASCENDING),
    SERIES("Series", SortDirection.ASCENDING),
    PROGRESS("Progress", SortDirection.DESCENDING),
    DURATION("Duration", SortDirection.DESCENDING),
    YEAR("Published year", SortDirection.DESCENDING),
    GOODREADS_RATING("Goodreads rating", SortDirection.DESCENDING),
}

data class SortDescriptor(val field: LibrarySort, val direction: SortDirection) {

    val summary: String get() = "${this.field.label} ${if (direction == SortDirection.ASCENDING) "asc" else "desc"}"
}

val DEFAULT_SORT = listOf(SortDescriptor(LibrarySort.RECENT, SortDirection.DESCENDING))

data class DrillDown(
    val title: String,
    val books: List<Book>,
    val kind: DrillKind,
    val shelf: BrowseGroup? = null,
    val page: Int = 0,
    val hasMore: Boolean = false,
    val loadingMore: Boolean = false,
)

data class BatchCollectionPickerState(
    val isVisible: Boolean = false,
    val isLoading: Boolean = false,
    val connection: LibraryConnectionOption? = null,
    val collections: List<BrowseGroup> = emptyList(),
)

@HiltViewModel
class HearthLibraryViewModel @Inject constructor(
    private val library: LibraryFacade,
    private val savedBooksFacade: SavedBooksFacade,
    private val playback: PlaybackFacade,
    private val prefs: PreferencesFacade,
    private val connectionRegistry: ConnectionRegistry,
) : ViewModel() {

    val query = MutableStateFlow("")
    val facet = MutableStateFlow(LibraryFacet.BOOKS)
    val status = MutableStateFlow(StatusFilter.ALL)
    val sourceFilter = MutableStateFlow<BookSource?>(null)
    val libraryFilter = MutableStateFlow<String?>(null)
    private var selectedLibraryConnectionId: String? = null
    private val explicitMedia = MutableStateFlow<MediaFilter?>(null)
    private var explicitMediaScope: String? = null

    private val _advancedFilters = MutableStateFlow(LibraryAdvancedFilters())
    val advancedFilters: StateFlow<LibraryAdvancedFilters> = _advancedFilters.asStateFlow()
    private var hasEditedAdvancedFilters = false
    private var hasEditedStatus = false
    private var hasEditedLibrarySelection = false

    val readingEnabled: StateFlow<Boolean> =
        prefs.readingEnabled.stateIn(viewModelScope, SharingStarted.Eagerly, true)
    val effectiveStatus: StateFlow<StatusFilter> =
        combine(status, readingEnabled) { selected, reading -> effectiveLibraryStatus(selected, reading) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, StatusFilter.ALL)

    val sortStack: StateFlow<List<SortDescriptor>> =
        prefs.librarySortStack.map(::decodeSortStack)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), DEFAULT_SORT)

    private val allBooks: StateFlow<List<Book>> =
        library.allBooks.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val savedBooks: StateFlow<Map<SavedBookList, List<Book>>> =
        combine(allBooks, savedBooksFacade.saved, readingEnabled) { books, saved, reading ->
            val byKey = books.filter { includesLibraryBook(it, reading) }.associateBy(Book::uniqueKey)
            SavedBookList.entries.associateWith { list -> saved[list].orEmpty().mapNotNull(byKey::get) }
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    private val excludedLibraryIds: StateFlow<Set<String>> =
        prefs.excludedLibraryIds.stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())

    private val visibleBooks: StateFlow<List<Book>> =
        combine(allBooks, excludedLibraryIds, readingEnabled) { books, excluded, reading ->
            books.excludingLibraries(excluded).filter { includesLibraryBook(it, reading) }
        }.flowOn(Dispatchers.Default)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _media = MutableStateFlow(MediaFilter.ALL)
    val media: StateFlow<MediaFilter> = _media.asStateFlow()
    val effectiveMedia: StateFlow<MediaFilter> =
        combine(media, readingEnabled) { selected, reading -> effectiveLibraryMedia(selected, reading) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, MediaFilter.ALL)

    val totalCount: StateFlow<Int> =
        library.totalCount.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val sources: StateFlow<List<BookSource>> =
        visibleBooks.map { list -> list.asSequence().map { it.source }.distinct().sortedBy { it.displayName }.toList() }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val libraries: StateFlow<List<Library>> =
        combine(library.libraries, sourceFilter, excludedLibraryIds) { libs, src, excluded ->
            val included = libs.filterNot { it.id in excluded }
            val scoped = if (src == null) included else included.filter { it.source == src }
            scoped
                .sortedWith(compareBy<Library> { it.name.lowercase() }.thenBy { it.id })
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val libraryConnectionLabels: StateFlow<Map<String, String>> =
        connectionRegistry.connections.map { connections ->
            connections.associate { connection ->
                connection.id to (connection.name.takeIf { it.isNotBlank() } ?: connection.serverUrl)
            }
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    private val hiddenIds: StateFlow<Set<String>> =
        library.hiddenBookIds.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptySet())

    val isRefreshing: StateFlow<Boolean> = library.isRefreshing
    val refreshError: StateFlow<String?> = library.refreshError
    val importIssues = combine(library.importIssues, sourceFilter, libraryFilter) { issues, source, selected ->
        issues.filter { issue ->
            (source == null || issue.report.source == source) && (selected == null || issue.scopeKey in setOf(
                com.enve.core.data.provider.catalogImportScopeKey(selected.substringBefore("::"), selected.substringAfter("::")),
                com.enve.core.data.provider.catalogImportScopeKey(selected.substringBefore("::"), null),
            ))
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())


    val columns: StateFlow<Int> =
        prefs.libraryColumns.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 3)
    val cardStyle: StateFlow<BookCardStyle> =
        prefs.bookCardStyle.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), BookCardStyle.STANDARD)

    private val libraryScope: StateFlow<String> =
        combine(sourceFilter, libraryFilter) { source, selectedLibrary -> libraryScopeKey(source, selectedLibrary) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, ALL_LIBRARY_SCOPE)
    private val _comicBrowse = MutableStateFlow(ComicBrowseState())
    val comicBrowse: StateFlow<ComicBrowseState> = _comicBrowse.asStateFlow()
    private var comicBrowseScope: String? = null

    val displayColumns: StateFlow<Int> =
        combine(columns, comicBrowse, effectiveMedia) { global, comics, selected ->
            if (selected == MediaFilter.COMICS) comics.columns ?: global else global
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 3)

    private data class Scope(
        val source: BookSource?,
        val libraryId: String?,
        val media: MediaFilter,
        val hidden: Set<String>,
    )

    private val scopeFilter = combine(sourceFilter, libraryFilter, effectiveMedia, hiddenIds) { src, lib, m, hid ->
        Scope(src, lib, m, hid)
    }

    private val baseScopedBooks: StateFlow<List<Book>> =
        combine(visibleBooks, scopeFilter) { list, scope ->
            list.filter { matchesScope(it, scope) }
        }.flowOn(Dispatchers.Default)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val scopedBooks: StateFlow<List<Book>> =
        combine(baseScopedBooks, advancedFilters) { books, filters ->
            books.filter { LibraryAdvancedFilterPolicy.matches(it, filters) }
        }.flowOn(Dispatchers.Default)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val advancedFilterOptions: StateFlow<LibraryAdvancedFilterOptions> =
        combine(baseScopedBooks, effectiveStatus) { books, selectedStatus ->
            LibraryAdvancedFilterPolicy.options(books.filter { matchesStatus(it, selectedStatus) })
        }.flowOn(Dispatchers.Default)
            .stateIn(
                viewModelScope,
                SharingStarted.WhileSubscribed(5000),
                LibraryAdvancedFilterOptions(),
            )

    private data class DisplayFilter(
        val query: String,
        val status: StatusFilter,
        val sort: List<SortDescriptor>,
        val scope: Scope,
        val advanced: LibraryAdvancedFilters,
    )

    private val displayFilter =
        combine(query, effectiveStatus, sortStack, scopeFilter, advancedFilters) { q, st, stack, scope, advanced ->
            DisplayFilter(q, st, stack, scope, advanced)
        }

    val books: StateFlow<List<Book>> =
        combine(visibleBooks, displayFilter) { list, filter ->
            list.asSequence()
                .filter { matchesScope(it, filter.scope) }
                .filter { matchesStatus(it, filter.status) }
                .filter { LibraryAdvancedFilterPolicy.matches(it, filter.advanced) }
                .filter { filter.query.isBlank() || matchesQuery(it, filter.query) }
                .sortedWith(comparatorFor(filter.sort))
                .toList()
        }.flowOn(Dispatchers.Default)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val comicSeries: StateFlow<List<ComicSeriesSummary>> =
        combine(books, effectiveMedia) { list, selected ->
            if (selected == MediaFilter.COMICS) comicSeriesSummaries(list) else emptyList()
        }.flowOn(Dispatchers.Default)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val comicSeriesView: StateFlow<ComicSeriesView?> =
        combine(baseScopedBooks, books, comicBrowse, effectiveMedia) { catalog, visible, state, selected ->
            state.seriesKey?.takeIf { selected == MediaFilter.COMICS }?.let { comicSeriesView(it, catalog, visible, state) }
        }.flowOn(Dispatchers.Default)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val selection = MutableStateFlow<Set<String>>(emptySet())
    val selectionMode = MutableStateFlow(false)

    val series: StateFlow<List<BrowseGroup>> = scopedBooks.map { list ->
        list.groupBy { it.seriesName?.trim().orEmpty() }
            .filterKeys { it.isNotBlank() }
            .map { (name, books) ->
                val unread = books.count { !isReadInLibrary(it) }
                BrowseGroup(
                    key = name,
                    name = name,
                    count = books.size,
                    coverUrl = books.firstNotNullOfOrNull(Book::coverUrl),
                    secondary = if (unread == 0) "✓ All read" else "$unread unread",
                )
            }
            .sortedBy { it.name.lowercase() }
    }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val authors: StateFlow<List<BrowseGroup>> = scopedBooks.map { list ->
        contributorGroups(list, Book::author)
    }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    private val _shelves = MutableStateFlow<List<BrowseGroup>>(emptyList())
    val shelves: StateFlow<List<BrowseGroup>> = _shelves
    private val _shelvesLoading = MutableStateFlow(false)
    val shelvesLoading: StateFlow<Boolean> = _shelvesLoading
    private val _bookOrbitCollectionConnections = MutableStateFlow<List<LibraryConnectionOption>>(emptyList())
    val bookOrbitCollectionConnections: StateFlow<List<LibraryConnectionOption>> = _bookOrbitCollectionConnections
    private val _batchCollectionPicker = MutableStateFlow(BatchCollectionPickerState())
    val batchCollectionPicker: StateFlow<BatchCollectionPickerState> = _batchCollectionPicker

    val hasGrimmoryConnection: StateFlow<Boolean> =
        connectionRegistry.connections.map { connections ->
            connections.any { it.enabled && it.source == BookSource.GRIMMORY }
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    private val _drill = MutableStateFlow<DrillDown?>(null)
    val drill: StateFlow<DrillDown?> = _drill
    private var shelfSearchJob: Job? = null
    private var shelfLoadJob: Job? = null
    private var drillGeneration: Long = 0L

    init {
        viewModelScope.launch {
            library.libraries.first { it.isNotEmpty() }
            savedBooksFacade.refresh()
        }
        viewModelScope.launch {
            val saved = decodeAdvancedFilters(prefs.libraryAdvancedFilters.first())
            if (!hasEditedAdvancedFilters) _advancedFilters.value = saved
        }
        viewModelScope.launch {
            val savedStatus = prefs.libraryStatus.first().let { raw -> StatusFilter.entries.firstOrNull { it.name == raw } }
            if (!hasEditedStatus) savedStatus?.let { status.value = it }
        }
        viewModelScope.launch {
            val saved = decodeLibrarySelection(prefs.librarySelection.first())
            if (saved == LibrarySelection()) return@launch
            val reading = prefs.readingEnabled.first()
            val visibleSources = library.allBooks
                .map { books -> books.asSequence().filter { includesLibraryBook(it, reading) }.mapTo(HashSet(), Book::source) }
                .flowOn(Dispatchers.Default)
                .first()
            val restored = restorableLibrarySelection(
                saved,
                visibleSources = visibleSources,
                libraries = library.libraries.first(),
                connections = connectionRegistry.connections.first(),
                excludedLibraryIds = prefs.excludedLibraryIds.first(),
            )
            if (hasEditedLibrarySelection) return@launch
            sourceFilter.value = restored.source
            libraryFilter.value = restored.libraryId
            selectedLibraryConnectionId = restored.connectionId
            if (restored != saved) persistLibrarySelection()
        }
        viewModelScope.launch {
            libraryScope.collectLatest { scope ->
                val savedMedia = MediaFilter.entries.firstOrNull { it.name == mediaPreference(scope).first() }
                val savedComics = decodeComicBrowseState(prefs.comicBrowseState(scope).first())
                if (scope != currentLibraryScope()) return@collectLatest
                if (explicitMediaScope != scope) {
                    explicitMediaScope = scope
                    explicitMedia.value = savedMedia
                }
                if (comicBrowseScope != scope) {
                    comicBrowseScope = scope
                    _comicBrowse.value = savedComics
                }
            }
        }
        viewModelScope.launch {
            excludedLibraryIds.collect { excluded ->
                if (libraryFilter.value in excluded) clearLibrarySelection()
                invalidateDrill()
            }
        }
        viewModelScope.launch {
            combine(explicitMedia, visibleBooks, sourceFilter, libraryFilter) { explicit, books, source, selectedLibrary ->
                resolveLibraryMedia(explicit, books, source, selectedLibrary)
            }.flowOn(Dispatchers.Default).collect { _media.value = it }
        }
        viewModelScope.launch {
            sources.collect { visibleSources ->
                val selectedSource = sourceFilter.value ?: return@collect
                if (visibleSources.isNotEmpty() && selectedSource !in visibleSources) {
                    sourceFilter.value = null
                    persistLibrarySelection()
                }
            }
        }
        viewModelScope.launch {
            library.libraries.collect { available ->
                val selected = libraryFilter.value ?: return@collect
                if (available.isNotEmpty() && available.none { it.id == selected }) clearLibrarySelection()
            }
        }
    }

    private fun currentLibraryScope(): String = libraryScopeKey(sourceFilter.value, libraryFilter.value)

    private fun mediaPreference(scope: String) =
        if (scope == ALL_LIBRARY_SCOPE) prefs.libraryMedia else prefs.scopedLibraryMedia(scope)

    private fun clearLibrarySelection() {
        libraryFilter.value = null
        selectedLibraryConnectionId = null
        persistLibrarySelection()
    }

    private fun persistLibrarySelection() {
        val selection = LibrarySelection(sourceFilter.value, libraryFilter.value, selectedLibraryConnectionId)
        viewModelScope.launch { prefs.setLibrarySelection(encodeLibrarySelection(selection)) }
    }

    fun setQuery(q: String) {
        query.value = q
        val shelf = _drill.value?.shelf ?: return
        shelfSearchJob?.cancel()
        shelfLoadJob?.cancel()
        val generation = nextDrillGeneration()
        shelfSearchJob = viewModelScope.launch {
            delay(300)
            val result = loadVisibleShelfPage(shelf.key, page = 0, query = q.ifBlank { null })
            if (!isCurrentShelfRequest(generation, shelf.key)) return@launch
            _drill.value = DrillDown(
                shelf.name,
                result.items.excludingLibraries(excludedLibraryIds.value),
                DrillKind.SHELF,
                shelf,
                result.page,
                result.hasMore,
            )
        }
    }
    fun setStatus(s: StatusFilter) {
        hasEditedStatus = true
        status.value = s
        viewModelScope.launch { prefs.setLibraryStatus(s.name) }
    }
    fun setSourceFilter(s: BookSource?) {
        hasEditedLibrarySelection = true
        val selectedLibrary = libraryFilter.value
        if (s != null && selectedLibrary != null && libraries.value.none { it.id == selectedLibrary && it.source == s }) {
            libraryFilter.value = null
            selectedLibraryConnectionId = null
        }
        sourceFilter.value = s
        persistLibrarySelection()
    }
    fun setLibraryFilter(name: String?) {
        hasEditedLibrarySelection = true
        val selected = name?.takeUnless { it in excludedLibraryIds.value }
        libraryFilter.value = selected
        selectedLibraryConnectionId = selected?.let { id -> libraries.value.firstOrNull { it.id == id }?.connectionId }
        persistLibrarySelection()
    }
    fun setMedia(m: MediaFilter) {
        val scope = currentLibraryScope()
        explicitMediaScope = scope
        explicitMedia.value = m
        _media.value = m
        viewModelScope.launch {
            if (scope == ALL_LIBRARY_SCOPE) prefs.setLibraryMedia(m.name) else prefs.setScopedLibraryMedia(scope, m.name)
        }
    }

    fun setComicFacet(f: LibraryFacet) = updateComicBrowse {
        it.copy(facet = f, seriesKey = null, section = null, expandedVolumeIds = emptySet())
    }

    fun openComicSeries(series: ComicSeriesSummary) = updateComicBrowse { state -> openedComicSeriesState(state, series) }

    fun closeComicSeries() = updateComicBrowse { it.copy(seriesKey = null, section = null, expandedVolumeIds = emptySet()) }

    fun selectComicSection(section: ComicSection) = updateComicBrowse { it.copy(section = section) }

    fun toggleComicVolume(id: String) = updateComicBrowse { state ->
        val expanded = state.expandedVolumeIds
        state.copy(expandedVolumeIds = if (id in expanded) expanded - id else expanded + id)
    }

    private fun updateComicBrowse(transform: (ComicBrowseState) -> ComicBrowseState) {
        val scope = currentLibraryScope()
        val next = transform(if (comicBrowseScope == scope) _comicBrowse.value else ComicBrowseState())
        comicBrowseScope = scope
        _comicBrowse.value = next
        viewModelScope.launch { prefs.setComicBrowseState(scope, encodeComicBrowseState(next)) }
    }

    fun toggleGenre(genre: String) {
        val current = advancedFilters.value
        val selected = current.genres.toMutableSet()
        if (!selected.add(genre)) selected.remove(genre)
        setAdvancedFilters(current.copy(genres = selected))
    }

    fun toggleLanguage(language: String) {
        val current = advancedFilters.value
        val selected = current.languages.toMutableSet()
        if (!selected.add(language)) selected.remove(language)
        setAdvancedFilters(current.copy(languages = selected))
    }

    fun setMinimumRating(rating: Float?) {
        setAdvancedFilters(advancedFilters.value.copy(minimumRating = rating))
    }

    fun setSeriesFilter(series: SeriesFilter) {
        setAdvancedFilters(advancedFilters.value.copy(series = series))
    }

    fun addSort(field: LibrarySort) = setSortStack(
        sortStack.value + SortDescriptor(field, field.defaultDirection),
    )

    fun removeSort(field: LibrarySort) = setSortStack(
        sortStack.value.filterNot { it.field == field },
    )

    fun setSortDirection(field: LibrarySort, direction: SortDirection) = setSortStack(
        sortStack.value.map { if (it.field == field) it.copy(direction = direction) else it },
    )

    fun setPrimaryDirection(direction: SortDirection) = setSortStack(
        sortStack.value.mapIndexed { i, d -> if (i == 0) d.copy(direction = direction) else d },
    )

    fun moveSortUp(field: LibrarySort) = moveSort(field, -1)
    fun moveSortDown(field: LibrarySort) = moveSort(field, +1)

    fun clearSorting() = setSortStack(emptyList())

    fun resetFiltersAndSorting() {
        setStatus(StatusFilter.ALL)
        setMedia(MediaFilter.ALL)
        setAdvancedFilters(LibraryAdvancedFilters())
        clearSorting()
    }

    private fun setAdvancedFilters(filters: LibraryAdvancedFilters) {
        hasEditedAdvancedFilters = true
        _advancedFilters.value = filters
        viewModelScope.launch {
            prefs.setLibraryAdvancedFilters(encodeAdvancedFilters(filters))
        }
    }

    private fun moveSort(field: LibrarySort, delta: Int) {
        val stack = sortStack.value.toMutableList()
        val index = stack.indexOfFirst { it.field == field }
        val target = index + delta
        if (index == -1 || target !in stack.indices) return
        val item = stack.removeAt(index)
        stack.add(target, item)
        setSortStack(stack)
    }

    private fun setSortStack(stack: List<SortDescriptor>) {
        viewModelScope.launch {
            prefs.setLibrarySortStack(encodeSortStack(stack))
        }
    }

    fun setFacet(f: LibraryFacet) {
        facet.value = f
        invalidateDrill()
        when (f) {
            LibraryFacet.SERIES, LibraryFacet.AUTHORS, LibraryFacet.NARRATORS -> Unit
            LibraryFacet.SHELVES -> if (_shelves.value.isEmpty()) loadShelves()
            LibraryFacet.BOOKS -> Unit
        }
    }

    val narrators: StateFlow<List<BrowseGroup>> = scopedBooks.map { list ->
        contributorGroups(list, Book::narrator)
    }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun openSeries(name: String) {
        invalidateDrill()
        _drill.value = DrillDown(
            name,
            seriesPlaybackOrder(scopedBooks.value.filter { it.seriesName?.trim() == name }),
            DrillKind.SERIES,
        )
    }
    fun openAuthor(name: String) {
        invalidateDrill()
        _drill.value = DrillDown(
            name,
            scopedBooks.value.filter { name in contributorNames(it.author) }.sortedWith(comparatorFor(sortStack.value)),
            DrillKind.AUTHOR,
        )
    }
    fun openNarrator(name: String) {
        invalidateDrill()
        _drill.value = DrillDown(
            name,
            scopedBooks.value.filter { name in contributorNames(it.narrator) }.sortedWith(comparatorFor(sortStack.value)),
            DrillKind.NARRATOR,
        )
    }
    fun openShelf(shelf: BrowseGroup) {
        shelfSearchJob?.cancel()
        shelfLoadJob?.cancel()
        val generation = nextDrillGeneration()
        shelfLoadJob = viewModelScope.launch {
            val result = loadVisibleShelfPage(shelf.key, page = 0, query = query.value.ifBlank { null })
            if (!isCurrentShelfRequest(generation, shelf.key, allowUnopened = true)) return@launch
            _drill.value = DrillDown(
                shelf.name,
                result.items,
                DrillKind.SHELF,
                shelf,
                result.page,
                result.hasMore,
            )
        }
    }
    fun loadMoreShelf() {
        val current = _drill.value ?: return
        val shelf = current.shelf ?: return
        if (!current.hasMore || current.loadingMore || shelfSearchJob?.isActive == true) return
        shelfLoadJob?.cancel()
        val generation = nextDrillGeneration()
        _drill.value = current.copy(loadingMore = true)
        shelfLoadJob = viewModelScope.launch {
            val result = loadVisibleShelfPage(shelf.key, page = current.page + 1, query = query.value.ifBlank { null })
            if (!isCurrentShelfRequest(generation, shelf.key)) return@launch
            _drill.value = current.copy(
                books = (current.books + result.items).distinctBy(Book::uniqueKey),
                page = result.page,
                hasMore = result.hasMore,
                loadingMore = false,
            )
        }
    }
    fun clearDrill() { invalidateDrill() }

    private suspend fun loadVisibleShelfPage(key: String, page: Int, query: String?): com.enve.engine.library.LibraryShelfPage {
        var nextPage = page
        while (true) {
            val result = library.shelfBooksPage(key, page = nextPage, query = query)
            val visible = result.items.excludingLibraries(excludedLibraryIds.value)
                .filter { includesLibraryBook(it, readingEnabled.value) }
            if (visible.isNotEmpty() || !result.hasMore) return result.copy(items = visible)
            nextPage = result.page + 1
        }
    }

    private fun nextDrillGeneration(): Long {
        drillGeneration += 1L
        return drillGeneration
    }

    private fun isCurrentShelfRequest(generation: Long, shelfKey: String, allowUnopened: Boolean = false): Boolean {
        if (generation != drillGeneration) return false
        val currentShelf = _drill.value?.shelf?.key
        return (allowUnopened && currentShelf == null) || currentShelf == shelfKey
    }

    private fun invalidateDrill() {
        nextDrillGeneration()
        shelfSearchJob?.cancel()
        shelfLoadJob?.cancel()
        _drill.value = null
    }

    private fun loadShelves() {
        if (_shelvesLoading.value) return
        viewModelScope.launch {
            _shelvesLoading.value = true
            try {
                _shelves.value = library.browseShelves()
                _bookOrbitCollectionConnections.value = library.bookOrbitCollectionConnections()
            } finally {
                _shelvesLoading.value = false
            }
        }
    }

    fun dismissImportIssues(issues: List<com.enve.core.data.provider.CatalogImportIssue>) = viewModelScope.launch {
        library.dismissImportIssues(issues)
    }

    fun refresh() = viewModelScope.launch {
        library.refresh()
        savedBooksFacade.refresh()
        if (_shelves.value.isNotEmpty() || facet.value == LibraryFacet.SHELVES) {
            _shelvesLoading.value = true
            try {
                _shelves.value = library.browseShelves()
            } finally {
                _shelvesLoading.value = false
            }
        }
    }

    fun cycleColumns() {
        val next = if (displayColumns.value >= 4) 1 else displayColumns.value + 1
        if (effectiveMedia.value == MediaFilter.COMICS) updateComicBrowse { it.copy(columns = next) }
        else viewModelScope.launch { prefs.setLibraryColumns(next) }
    }

    fun createBookOrbitCollection(connectionId: String, edit: BookOrbitCollectionEdit) = viewModelScope.launch {
        if (library.createBookOrbitCollection(connectionId, edit) == null) {
            notice.value = "Couldn't create the BookOrbit collection. An administrator account is required."
        }
        reloadShelves()
    }

    fun updateBookOrbitCollection(collection: BrowseGroup, edit: BookOrbitCollectionEdit) = viewModelScope.launch {
        if (library.updateBookOrbitCollection(collection, edit) == null) notice.value = "Couldn't update the BookOrbit collection."
        reloadShelves()
    }

    fun deleteBookOrbitCollection(collection: BrowseGroup) = viewModelScope.launch {
        if (!library.deleteBookOrbitCollection(collection)) notice.value = "Couldn't delete the BookOrbit collection."
        _drill.value = null
        reloadShelves()
    }

    fun removeBookFromShelf(book: Book) = viewModelScope.launch {
        val current = _drill.value ?: return@launch
        val shelf = current.shelf ?: return@launch
        if (library.removeBookFromBookOrbitCollection(shelf, book)) {
            _drill.value = current.copy(books = current.books.filterNot { it.id == book.id })
        } else {
            notice.value = "Couldn't remove the book from the BookOrbit collection."
        }
        reloadShelves()
    }

    fun moveBookOrbitCollection(collection: BrowseGroup, delta: Int) = viewModelScope.launch {
        val connectionId = collection.sourceConnectionId ?: return@launch
        val ordered = _shelves.value
            .filter { it.source == BookSource.BOOKORBIT && it.sourceConnectionId == connectionId }
            .sortedBy { it.displayOrder }
            .toMutableList()
        val index = ordered.indexOfFirst { it.key == collection.key }
        val target = index + delta
        if (index == -1 || target !in ordered.indices) return@launch
        val item = ordered.removeAt(index)
        ordered.add(target, item)
        if (!library.reorderBookOrbitCollections(connectionId, ordered.map { it.key })) {
            notice.value = "Couldn't reorder the BookOrbit collections."
        }
        reloadShelves()
    }

    private suspend fun reloadShelves() {
        _shelves.value = library.browseShelves()
        _bookOrbitCollectionConnections.value = library.bookOrbitCollectionConnections()
    }

    fun openBatchCollectionPicker() {
        val targets = selectedBooks()
        val connectionId = targets.map { it.connectionId }.distinct().singleOrNull()
        if (targets.isEmpty() || connectionId == null || targets.any { it.source != BookSource.BOOKORBIT }) {
            notice.value = "Collections require books from the same BookOrbit server."
            return
        }

        _batchCollectionPicker.value = BatchCollectionPickerState(isVisible = true, isLoading = true)
        viewModelScope.launch {
            val connection = library.bookOrbitCollectionConnections().firstOrNull { it.id == connectionId }
            if (connection == null) {
                _batchCollectionPicker.value = BatchCollectionPickerState()
                notice.value = "Reconnect to BookOrbit to edit your collections."
                return@launch
            }
            val collections = library.browseShelves().filter {
                it.source == BookSource.BOOKORBIT && it.sourceConnectionId == connectionId && it.isEditable
            }
            _batchCollectionPicker.value = BatchCollectionPickerState(
                isVisible = true,
                connection = connection,
                collections = collections,
            )
        }
    }

    fun closeBatchCollectionPicker() {
        _batchCollectionPicker.value = BatchCollectionPickerState()
    }

    fun addSelectedToBookOrbitCollection(collection: BrowseGroup) {
        val targets = selectedBooks()
        closeBatchCollectionPicker()
        endSelection()
        viewModelScope.launch {
            if (library.addBooksToBookOrbitCollection(collection, targets)) {
                notice.value = "Added ${targets.size} ${if (targets.size == 1) "book" else "books"} to \"${collection.name}\"."
            } else {
                notice.value = "Couldn't add the selected books to the BookOrbit collection."
            }
            reloadShelves()
        }
    }

    fun createBookOrbitCollectionFromSelection(connectionId: String, edit: BookOrbitCollectionEdit) {
        val targets = selectedBooks()
        closeBatchCollectionPicker()
        endSelection()
        viewModelScope.launch {
            val collection = library.createBookOrbitCollection(connectionId, edit)
            if (collection == null) {
                notice.value = "Couldn't create the BookOrbit collection. An administrator account is required."
            } else if (!library.addBooksToBookOrbitCollection(collection, targets)) {
                notice.value = "Created \"${collection.name}\", but couldn't add the selected books."
            } else {
                notice.value = "Created \"${collection.name}\" with ${targets.size} ${if (targets.size == 1) "book" else "books"}."
            }
            reloadShelves()
        }
    }

    val notice = MutableStateFlow<String?>(null)
    fun dismissNotice() { notice.value = null }

    fun setFinished(book: Book, finished: Boolean) = viewModelScope.launch {
        if (!library.setFinished(book, finished)) {
            notice.value = "Couldn't update \"${book.title}\" on the server."
        }
    }
    fun hide(book: Book) = viewModelScope.launch { library.setHidden(book.id, true) }
    fun download(book: Book) = viewModelScope.launch { library.download(book) }
    fun removeDownload(book: Book) = viewModelScope.launch { library.removeDownload(book) }

    fun playAllDrill(): Boolean {
        val current = _drill.value ?: return false
        if (current.kind == DrillKind.SHELF || current.books.none(Book::hasPlayableAudio)) return false
        playback.playAll(current.books, "${current.kind.name}:${current.title}")
        return true
    }

    fun playSelected(): Boolean {
        val targets = selectedBooks()
        if (targets.none(Book::hasPlayableAudio)) {
            notice.value = "The selected books don't contain playable audio."
            return false
        }
        endSelection()
        playback.playAll(targets, "SELECTION")
        return true
    }

    fun addNext(book: Book) {
        if (!book.hasPlayableAudio) return
        playback.addNext(book)
        notice.value = "\"${book.title}\" will play next."
    }

    fun addLast(book: Book) {
        if (!book.hasPlayableAudio) return
        playback.addLast(book)
        notice.value = "Added \"${book.title}\" to Up Next."
    }

    fun beginSelection() {
        selectionMode.value = true
        selection.value = emptySet()
    }

    fun startSelection(book: Book) {
        selectionMode.value = true
        selection.value = setOf(book.uniqueKey)
    }

    fun toggleSelected(book: Book) {
        selection.value = if (book.uniqueKey in selection.value) selection.value - book.uniqueKey else selection.value + book.uniqueKey
    }

    fun selectAllVisible() { selection.value = selectionCandidates().map { it.uniqueKey }.toSet() }

    fun endSelection() {
        closeBatchCollectionPicker()
        selectionMode.value = false
        selection.value = emptySet()
    }

    fun bulkAddToUpNext() {
        val targets = selectedBooks().filter(Book::hasPlayableAudio)
        if (targets.isEmpty()) {
            notice.value = "The selected books don't contain playable audio."
            return
        }
        endSelection()
        playback.addLast(targets)
        notice.value = "Added ${targets.size} ${if (targets.size == 1) "book" else "books"} to Up Next."
    }

    fun bulkFinished(finished: Boolean) {
        val targets = selectedBooks()
        endSelection()
        viewModelScope.launch {
            val failed = targets.count { !library.setFinished(it, finished) }
            if (failed > 0) notice.value = "Couldn't update $failed of ${targets.size} books."
        }
    }

    fun bulkHide() = bulk { library.setHidden(it.id, true) }
    fun bulkDownload() = bulk { library.download(it) }

    private fun bulk(action: suspend (Book) -> Unit) {
        val targets = selectedBooks()
        endSelection()
        viewModelScope.launch { targets.forEach { action(it) } }
    }

    private fun selectionCandidates(): List<Book> = _drill.value?.books ?: books.value

    private fun selectedBooks(): List<Book> = selectionCandidates().filter { it.uniqueKey in selection.value }

    private fun matchesScope(book: Book, scope: Scope): Boolean =
        book.id !in scope.hidden &&
            (scope.source == null || book.source == scope.source) &&
            (scope.libraryId == null || book.libraryId == scope.libraryId) &&
            matchesMedia(book, scope.media)

    private fun matchesMedia(b: Book, m: MediaFilter): Boolean = when (m) {
        MediaFilter.ALL -> true
        MediaFilter.AUDIOBOOKS -> b.mediaType == AppMediaType.AUDIOBOOK
        MediaFilter.EBOOKS -> b.mediaType == AppMediaType.EBOOK
        MediaFilter.COMICS -> b.isComic
    }

    private fun matchesStatus(b: Book, s: StatusFilter): Boolean = when (s) {
        StatusFilter.ALL -> true
        StatusFilter.CURRENTLY_READING -> inProgress(b)
        StatusFilter.UNREAD -> !isReadInLibrary(b)
        StatusFilter.LISTENING -> b.mediaType == AppMediaType.AUDIOBOOK && inProgress(b)
        StatusFilter.READING -> b.mediaType == AppMediaType.EBOOK && inProgress(b)
        StatusFilter.FINISHED -> isReadInLibrary(b)
        StatusFilter.DOWNLOADED -> b.isDownloaded
    }

    private fun inProgress(b: Book): Boolean =
        !isReadInLibrary(b) && statusAllowsContinue(b) &&
            (b.readStatus == ReadStatus.IN_PROGRESS ||
                b.serverReadStatus?.uppercase() in setOf("READING", "RE_READING", "IN_PROGRESS") ||
                b.readProgress in 0.01f..FINISHED_PROGRESS_THRESHOLD || b.currentTime > 0L || (b.epubProgress ?: 0f) in 0.01f..FINISHED_PROGRESS_THRESHOLD)

    private fun statusAllowsContinue(book: Book): Boolean {
        if (book.source != BookSource.GRIMMORY && book.source != BookSource.BOOKORBIT) return true
        val status = book.serverReadStatus?.uppercase() ?: return true
        return status == "READING" || status == "RE_READING" || status == "IN_PROGRESS"
    }

    private fun contributorGroups(books: List<Book>, selector: (Book) -> String?): List<BrowseGroup> {
        val groups = linkedMapOf<String, MutableList<Book>>()
        books.forEach { book -> contributorNames(selector(book)).forEach { groups.getOrPut(it, ::mutableListOf).add(book) } }
        return groups.map { (name, matches) ->
            BrowseGroup(key = name, name = name, count = matches.size, coverUrl = matches.firstNotNullOfOrNull(Book::coverUrl))
        }.sortedBy { it.name.lowercase() }
    }

    private fun contributorNames(raw: String?): List<String> =
        raw.orEmpty().split(",").map(String::trim).filter(String::isNotBlank)

    private fun matchesQuery(b: Book, q: String): Boolean {
        val needle = q.trim()
        return b.title.contains(needle, ignoreCase = true) ||
            (b.author?.contains(needle, ignoreCase = true) == true) ||
            (b.seriesName?.contains(needle, ignoreCase = true) == true) ||
            (b.narrator?.contains(needle, ignoreCase = true) == true)
    }

    private fun comparatorFor(stack: List<SortDescriptor>): Comparator<Book> = Comparator { a, b ->
        for (descriptor in stack.ifEmpty { DEFAULT_SORT }) {
            val aMissing = missingSortValue(a, descriptor.field)
            val bMissing = missingSortValue(b, descriptor.field)
            if (aMissing != bMissing) return@Comparator if (aMissing) 1 else -1
            val cmp = sortComparison(a, b, descriptor.field)
            if (cmp != 0) {
                return@Comparator if (descriptor.direction == SortDirection.ASCENDING) cmp else -cmp
            }
        }
        a.title.compareTo(b.title, ignoreCase = true)
    }

    private fun missingSortValue(b: Book, field: LibrarySort): Boolean = when (field) {
        LibrarySort.RECENT -> b.lastReadTime <= 0L && b.addedOn <= 0L
        LibrarySort.TITLE -> b.title.isBlank()
        LibrarySort.AUTHOR, LibrarySort.AUTHOR_SURNAME -> b.author.isNullOrBlank()
        LibrarySort.NARRATOR, LibrarySort.NARRATOR_SURNAME -> b.narrator.isNullOrBlank()
        LibrarySort.SERIES -> b.seriesName.isNullOrBlank()
        LibrarySort.PROGRESS -> false
        LibrarySort.DURATION -> b.duration <= 0L
        LibrarySort.YEAR -> publishedYear(b) == null
        LibrarySort.GOODREADS_RATING -> b.goodreadsRating == null
    }

    private fun sortComparison(a: Book, b: Book, field: LibrarySort): Int = when (field) {
        LibrarySort.RECENT -> recentStamp(a).compareTo(recentStamp(b))
        LibrarySort.TITLE -> a.title.compareTo(b.title, ignoreCase = true)
        LibrarySort.AUTHOR -> (a.author ?: "").compareTo(b.author ?: "", ignoreCase = true)
        LibrarySort.AUTHOR_SURNAME -> surname(a.author).compareTo(surname(b.author), ignoreCase = true)
        LibrarySort.NARRATOR -> (a.narrator ?: "").compareTo(b.narrator ?: "", ignoreCase = true)
        LibrarySort.NARRATOR_SURNAME -> surname(a.narrator).compareTo(surname(b.narrator), ignoreCase = true)
        LibrarySort.SERIES -> {
            val bySeries = (a.seriesName ?: "").compareTo(b.seriesName ?: "", ignoreCase = true)
            if (bySeries != 0) bySeries
            else (a.seriesNumber?.toFloatOrNull() ?: Float.MAX_VALUE)
                .compareTo(b.seriesNumber?.toFloatOrNull() ?: Float.MAX_VALUE)
        }
        LibrarySort.PROGRESS -> bookProgress(a).compareTo(bookProgress(b))
        LibrarySort.DURATION -> a.duration.compareTo(b.duration)
        LibrarySort.YEAR -> (publishedYear(a) ?: 0).compareTo(publishedYear(b) ?: 0)
        LibrarySort.GOODREADS_RATING -> (a.goodreadsRating ?: 0f).compareTo(b.goodreadsRating ?: 0f)
    }

    private fun recentStamp(b: Book): Long = maxOf(b.lastReadTime, b.addedOn)

    private fun bookProgress(b: Book): Float =
        maxOf(b.readProgress, b.epubProgress ?: 0f, if (b.duration > 0) b.currentTime.toFloat() / b.duration else 0f)

    private fun surname(name: String?): String {
        val cleaned = name?.trim().orEmpty()
        if (cleaned.isEmpty()) return ""
        cleaned.substringBefore(',', "").trim().takeIf { it.isNotEmpty() && cleaned.contains(',') }?.let { return it }
        return cleaned.split(';', '&').first().trim().substringAfterLast(' ')
    }
}

private val PublishedYearPattern = Regex("\\d{4}")

internal fun publishedYear(book: Book): Int? =
    book.publishedDate?.let { PublishedYearPattern.find(it)?.value?.toIntOrNull() }

internal const val ALL_LIBRARY_SCOPE = "all"

internal fun libraryScopeKey(source: BookSource?, libraryId: String?): String =
    libraryId?.let { "library:$it" } ?: source?.let { "source:${it.name}" } ?: ALL_LIBRARY_SCOPE

internal fun resolveLibraryMedia(
    explicit: MediaFilter?,
    books: List<Book>,
    source: BookSource?,
    libraryId: String?,
): MediaFilter {
    if (explicit != null) return explicit
    if (source == null && libraryId == null) return MediaFilter.ALL
    val scoped = books.asSequence().filter { (source == null || it.source == source) && (libraryId == null || it.libraryId == libraryId) }
    return if (scoped.any() && scoped.all { it.isComic }) MediaFilter.COMICS else MediaFilter.ALL
}

@Serializable
internal data class LibrarySelection(
    val source: BookSource? = null,
    val libraryId: String? = null,
    val connectionId: String? = null,
)

private val LibrarySelectionJson = Json { ignoreUnknownKeys = true }

internal fun encodeLibrarySelection(selection: LibrarySelection): String = LibrarySelectionJson.encodeToString(selection)

internal fun decodeLibrarySelection(encoded: String): LibrarySelection =
    runCatching { LibrarySelectionJson.decodeFromString<LibrarySelection>(encoded) }.getOrNull() ?: LibrarySelection()

internal fun restorableLibrarySelection(
    saved: LibrarySelection,
    visibleSources: Set<BookSource>,
    libraries: List<Library>,
    connections: List<ProviderConnection>,
    excludedLibraryIds: Set<String>,
): LibrarySelection {
    val enabled = connections.filter(ProviderConnection::enabled)
    val source = saved.source?.takeIf { it in visibleSources || (visibleSources.isEmpty() && enabled.any { c -> c.source == it }) }
    val libraryId = saved.libraryId?.takeIf { id ->
        (saved.source == null || source != null) &&
            id !in excludedLibraryIds &&
            (libraries.isEmpty() || libraries.any { it.id == id }) &&
            (saved.connectionId == null || enabled.any { it.id == saved.connectionId })
    }
    return LibrarySelection(source, libraryId, saved.connectionId.takeIf { libraryId != null })
}

internal fun isReadInLibrary(book: Book): Boolean =
    book.isFinished || book.readStatus == ReadStatus.COMPLETED ||
        book.serverReadStatus?.uppercase() in setOf("READ", "COMPLETED", "FINISHED")

internal fun effectiveLibraryMedia(selected: MediaFilter, readingEnabled: Boolean): MediaFilter =
    if (!readingEnabled && selected in ReadingMediaFilters) MediaFilter.ALL else selected

internal fun effectiveLibraryStatus(selected: StatusFilter, readingEnabled: Boolean): StatusFilter =
    if (!readingEnabled && selected == StatusFilter.READING) StatusFilter.LISTENING else selected

internal fun availableLibraryMedia(readingEnabled: Boolean): List<MediaFilter> =
    MediaFilter.entries.filter { readingEnabled || it !in ReadingMediaFilters }

internal fun availableLibraryStatuses(readingEnabled: Boolean): List<StatusFilter> =
    StatusFilter.entries.filter { readingEnabled || it != StatusFilter.READING }

private val ReadingMediaFilters = setOf(MediaFilter.EBOOKS, MediaFilter.COMICS)

internal fun seriesPlaybackOrder(books: List<Book>): List<Book> = books.sortedWith(
    compareBy<Book> { seriesOrdinal(it.seriesNumber) == null }
        .thenBy { seriesOrdinal(it.seriesNumber) ?: Double.MAX_VALUE }
        .thenBy { it.title.lowercase() },
)

private fun seriesOrdinal(raw: String?): Double? =
    raw?.trim()?.toDoubleOrNull()
        ?: raw?.let { Regex("""\d+(?:\.\d+)?""").find(it)?.value?.toDoubleOrNull() }

internal fun List<Book>.excludingLibraries(excludedLibraryIds: Set<String>): List<Book> =
    if (excludedLibraryIds.isEmpty()) this else filter { book ->
        book.libraryId == null || book.libraryId !in excludedLibraryIds
    }

internal fun libraryActiveFilterCount(
    status: StatusFilter,
    media: MediaFilter,
    advanced: LibraryAdvancedFilters,
): Int = (if (status != StatusFilter.ALL) 1 else 0) +
    (if (media != MediaFilter.ALL) 1 else 0) +
    advanced.genres.size + advanced.languages.size +
    (if (advanced.minimumRating != null) 1 else 0) +
    (if (advanced.series != SeriesFilter.ALL) 1 else 0)

internal fun encodeSortStack(stack: List<SortDescriptor>): String =
    if (stack.isEmpty()) "[]"
    else stack.distinctBy { it.field }.joinToString(",") { "${it.field.name}:${it.direction.name}" }

internal fun decodeSortStack(encoded: String): List<SortDescriptor> {
    if (encoded == "[]") return emptyList()
    if (encoded.isBlank()) return DEFAULT_SORT
    val parsed = encoded.split(',').mapNotNull { entry ->
        val (fieldName, dirName) = entry.split(':').takeIf { it.size == 2 } ?: return@mapNotNull null
        val field = runCatching { LibrarySort.valueOf(fieldName) }.getOrNull() ?: return@mapNotNull null
        val direction = runCatching { SortDirection.valueOf(dirName) }.getOrNull() ?: return@mapNotNull null
        SortDescriptor(field, direction)
    }.distinctBy { it.field }
    return parsed.ifEmpty { DEFAULT_SORT }
}

private fun encodeAdvancedFilters(filters: LibraryAdvancedFilters): String {
    if (!filters.isActive) return ""
    return listOf(
        "g=${encodeFilterValues(filters.genres)}",
        "l=${encodeFilterValues(filters.languages)}",
        "r=${filters.minimumRating ?: ""}",
        "s=${filters.series.name}",
    ).joinToString(";")
}

private fun decodeAdvancedFilters(encoded: String): LibraryAdvancedFilters {
    if (encoded.isBlank()) return LibraryAdvancedFilters()
    val values = encoded.split(';')
        .mapNotNull { part ->
            val index = part.indexOf('=')
            if (index <= 0) null else part.take(index) to part.drop(index + 1)
        }
        .toMap()
    return LibraryAdvancedFilters(
        genres = decodeFilterValues(values["g"].orEmpty()),
        languages = decodeFilterValues(values["l"].orEmpty()),
        minimumRating = values["r"]?.toFloatOrNull(),
        series = values["s"]
            ?.let { runCatching { SeriesFilter.valueOf(it) }.getOrNull() }
            ?: SeriesFilter.ALL,
    )
}

private fun encodeFilterValues(values: Set<String>): String =
    values.sortedWith(String.CASE_INSENSITIVE_ORDER).joinToString(",") { value ->
        Base64.getUrlEncoder().withoutPadding().encodeToString(value.toByteArray(Charsets.UTF_8))
    }

private fun decodeFilterValues(encoded: String): Set<String> =
    encoded.split(',')
        .mapNotNull { value ->
            if (value.isBlank()) return@mapNotNull null
            runCatching {
                String(Base64.getUrlDecoder().decode(value), Charsets.UTF_8)
            }.getOrNull()
        }
        .toSet()
