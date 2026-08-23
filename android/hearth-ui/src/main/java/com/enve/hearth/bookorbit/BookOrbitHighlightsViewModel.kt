package com.enve.hearth.bookorbit

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.Book
import com.enve.engine.bookorbit.BookOrbitAccount
import com.enve.engine.bookorbit.BookOrbitExportFormat
import com.enve.engine.bookorbit.BookOrbitFacade
import com.enve.engine.bookorbit.BookOrbitHighlight
import com.enve.engine.bookorbit.BookOrbitHighlightBookFacet
import com.enve.engine.bookorbit.BookOrbitHighlightExport
import com.enve.engine.bookorbit.BookOrbitHighlightPage
import com.enve.engine.bookorbit.BookOrbitHighlightQuery
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class BookOrbitHighlightStats(
    val total: Int = 0,
    val books: Int = 0,
    val withNotes: Int = 0,
)

@HiltViewModel
class BookOrbitHighlightsViewModel @Inject constructor(
    private val bookOrbit: BookOrbitFacade,
) : ViewModel() {
    val accounts: StateFlow<List<BookOrbitAccount>> =
        bookOrbit.accounts.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val chosenAccountId = MutableStateFlow<String?>(null)
    private val filter = MutableStateFlow(BookOrbitHighlightQuery())

    private val _searchInput = MutableStateFlow("")
    val searchInput: StateFlow<String> = _searchInput.asStateFlow()

    private val _state = MutableStateFlow<BookOrbitLoad<Unit>>(BookOrbitLoad.Loading)
    val state: StateFlow<BookOrbitLoad<Unit>> = _state.asStateFlow()

    private val _items = MutableStateFlow<List<BookOrbitHighlight>>(emptyList())
    val items: StateFlow<List<BookOrbitHighlight>> = _items.asStateFlow()

    private val _stats = MutableStateFlow(BookOrbitHighlightStats())
    val stats: StateFlow<BookOrbitHighlightStats> = _stats.asStateFlow()

    private val _books = MutableStateFlow<List<BookOrbitHighlightBookFacet>>(emptyList())
    val books: StateFlow<List<BookOrbitHighlightBookFacet>> = _books.asStateFlow()

    private val _hasMore = MutableStateFlow(false)
    val hasMore: StateFlow<Boolean> = _hasMore.asStateFlow()

    private val _loadingMore = MutableStateFlow(false)
    val loadingMore: StateFlow<Boolean> = _loadingMore.asStateFlow()

    private val _notice = MutableStateFlow<String?>(null)
    val notice: StateFlow<String?> = _notice.asStateFlow()

    val query: StateFlow<BookOrbitHighlightQuery> = filter.asStateFlow()

    val activeAccountId: StateFlow<String?> = combine(accounts, chosenAccountId) { available, chosen ->
        chosen?.takeIf { id -> available.any { it.connectionId == id } } ?: available.firstOrNull()?.connectionId
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    private var loadedPage = 1

    init {
        viewModelScope.launch {
            _searchInput.collectLatest { text ->
                if (text != filter.value.search) {
                    delay(SEARCH_DEBOUNCE_MS)
                    filter.update { it.copy(search = text) }
                }
            }
        }
        viewModelScope.launch {
            combine(accounts, activeAccountId, filter) { available, id, query ->
                HighlightRequest(available.isNotEmpty(), id, query)
            }.distinctUntilChanged().collectLatest(::reload)
        }
        viewModelScope.launch {
            combine(activeAccountId, filter) { id, query -> id to query.trashed }
                .distinctUntilChanged()
                .collectLatest { (id, isTrashed) ->
                    _books.value = if (id == null) emptyList() else bookOrbit.highlightBooks(id, isTrashed, "")
                }
        }
    }

    fun selectAccount(connectionId: String) {
        chosenAccountId.value = connectionId
    }

    fun setSearch(text: String) {
        _searchInput.value = text
    }

    fun setTrashed(value: Boolean) {
        filter.update { it.copy(trashed = value, bookId = null) }
    }

    fun setNotesOnly(value: Boolean) {
        filter.update { it.copy(notesOnly = value) }
    }

    fun selectBook(bookId: Int?) {
        filter.update { it.copy(bookId = bookId) }
    }

    fun retry() {
        viewModelScope.launch {
            reload(HighlightRequest(accounts.value.isNotEmpty(), activeAccountId.value, filter.value))
        }
    }

    fun loadMore() {
        if (!_hasMore.value || _loadingMore.value) return
        val connectionId = activeAccountId.value ?: return
        val requested = filter.value
        _loadingMore.value = true
        viewModelScope.launch {
            val nextPage = loadedPage + 1
            val page = try {
                bookOrbit.highlights(connectionId, requested.copy(page = nextPage))
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
            if (filter.value == requested && activeAccountId.value == connectionId) {
                if (page != null) {
                    loadedPage = nextPage
                    _items.update { current -> (current + page.items).distinctBy(BookOrbitHighlight::id) }
                    _hasMore.value = page.hasMore
                } else {
                    _hasMore.value = false
                }
            }
            _loadingMore.value = false
        }
    }

    fun trash(highlight: BookOrbitHighlight) {
        mutate(highlight, "Moved to the BookOrbit trash.") { connectionId ->
            bookOrbit.trashHighlights(connectionId, listOf(highlight.id)) > 0
        }
    }

    fun restore(highlight: BookOrbitHighlight) {
        mutate(highlight, "Restored to your library.") { connectionId ->
            bookOrbit.restoreHighlights(connectionId, listOf(highlight.id)) > 0
        }
    }

    fun deleteForever(highlight: BookOrbitHighlight) {
        mutate(highlight, "Deleted from BookOrbit.") { connectionId ->
            bookOrbit.deleteHighlight(connectionId, highlight.id)
        }
    }

    fun export(format: BookOrbitExportFormat, onReady: (BookOrbitHighlightExport) -> Unit) {
        val connectionId = activeAccountId.value ?: return
        viewModelScope.launch {
            val export = try {
                bookOrbit.exportHighlights(connectionId, filter.value, format)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
            if (export == null) {
                _notice.value = "Couldn't export those highlights."
            } else {
                onReady(export)
            }
        }
    }

    suspend fun openBook(bookId: Int): Book? =
        activeAccountId.value?.let { bookOrbit.openBook(it, bookId) }

    fun dismissNotice() {
        _notice.value = null
    }

    private fun mutate(
        highlight: BookOrbitHighlight,
        successMessage: String,
        action: suspend (String) -> Boolean,
    ) {
        val connectionId = activeAccountId.value ?: return
        viewModelScope.launch {
            val changed = try {
                action(connectionId)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                false
            }
            if (changed) {
                _items.update { current -> current.filterNot { it.id == highlight.id } }
                _stats.update { it.copy(total = (it.total - 1).coerceAtLeast(0)) }
                _notice.value = successMessage
            } else {
                _notice.value = "BookOrbit rejected that change."
            }
        }
    }

    private suspend fun reload(request: HighlightRequest) {
        if (!request.hasAccounts || request.connectionId == null) {
            _state.value = BookOrbitLoad.NoAccount
            _items.value = emptyList()
            _hasMore.value = false
            return
        }
        _state.value = BookOrbitLoad.Loading
        loadedPage = 1
        val loaded = loadBookOrbit {
            bookOrbit.highlights(request.connectionId, request.query.copy(page = 1))
        }
        _state.value = when (loaded) {
            is BookOrbitLoad.Ready -> {
                applyPage(loaded.value)
                BookOrbitLoad.Ready(Unit)
            }
            BookOrbitLoad.Failed -> BookOrbitLoad.Failed
            else -> BookOrbitLoad.Unavailable
        }
        if (_state.value !is BookOrbitLoad.Ready) {
            _items.value = emptyList()
            _hasMore.value = false
        }
    }

    private fun applyPage(page: BookOrbitHighlightPage) {
        _items.value = page.items
        _hasMore.value = page.hasMore
        _stats.value = BookOrbitHighlightStats(
            total = page.total,
            books = page.books,
            withNotes = page.withNotes,
        )
    }

    private data class HighlightRequest(
        val hasAccounts: Boolean,
        val connectionId: String?,
        val query: BookOrbitHighlightQuery,
    )

    private companion object {
        const val SEARCH_DEBOUNCE_MS = 300L
    }
}
