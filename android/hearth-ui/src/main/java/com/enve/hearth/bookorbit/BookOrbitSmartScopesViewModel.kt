package com.enve.hearth.bookorbit

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.Book
import com.enve.engine.bookorbit.BookOrbitAccount
import com.enve.engine.bookorbit.BookOrbitFacade
import com.enve.engine.bookorbit.BookOrbitFailureReason
import com.enve.engine.bookorbit.BookOrbitSmartScope
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
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
import kotlinx.coroutines.flow.updateAndGet
import kotlinx.coroutines.launch
import javax.inject.Inject

data class BookOrbitSmartScopesState(
    val loading: Boolean = true,
    val noAccount: Boolean = false,
    val unsupported: Boolean = false,
    val loadedAccountId: String? = null,
    val scopes: List<BookOrbitSmartScope> = emptyList(),
    val failure: BookOrbitFailureReason? = null,
    val selectedScopeId: Int? = null,
) {
    val loaded: Boolean get() = loadedAccountId != null
    val selectedScope: BookOrbitSmartScope? get() = scopes.firstOrNull { it.id == selectedScopeId }
}

@HiltViewModel
class BookOrbitSmartScopesViewModel @Inject constructor(
    private val bookOrbit: BookOrbitFacade,
) : ViewModel() {
    val accounts: StateFlow<List<BookOrbitAccount>> =
        bookOrbit.accounts.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val chosenAccountId = MutableStateFlow<String?>(null)
    private val scopeReloads = MutableStateFlow(0)
    private val appliedSearch = MutableStateFlow("")

    val activeAccountId: StateFlow<String?> = combine(accounts, chosenAccountId) { available, chosen ->
        chosen?.takeIf { id -> available.any { it.connectionId == id } } ?: available.firstOrNull()?.connectionId
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    private val _state = MutableStateFlow(BookOrbitSmartScopesState())
    val state: StateFlow<BookOrbitSmartScopesState> = _state.asStateFlow()

    private val _searchInput = MutableStateFlow("")
    val searchInput: StateFlow<String> = _searchInput.asStateFlow()

    private val _books = MutableStateFlow(BookOrbitPagedList<Book>(firstPage = FIRST_PAGE))
    val books: StateFlow<BookOrbitPagedList<Book>> = _books.asStateFlow()

    private val _booksFailure = MutableStateFlow<BookOrbitFailureReason?>(null)
    val booksFailure: StateFlow<BookOrbitFailureReason?> = _booksFailure.asStateFlow()

    private var firstPageJob: Job? = null
    private var nextPageJob: Job? = null

    init {
        viewModelScope.launch {
            _searchInput.collectLatest { text ->
                val trimmed = text.trim()
                if (trimmed != appliedSearch.value) {
                    delay(SEARCH_DEBOUNCE_MS)
                    appliedSearch.value = trimmed
                }
            }
        }
        viewModelScope.launch {
            combine(accounts, activeAccountId, scopeReloads) { available, id, reload ->
                Triple(available.isNotEmpty(), id, reload)
            }.distinctUntilChanged().collectLatest { (hasAccounts, connectionId, _) ->
                loadScopes(hasAccounts, connectionId)
            }
        }
        viewModelScope.launch {
            combine(_state, appliedSearch) { current, search ->
                BooksRequest(current.loadedAccountId, current.selectedScopeId, search)
            }.distinctUntilChanged().collect(::restartBooks)
        }
    }

    fun selectAccount(connectionId: String) {
        chosenAccountId.value = connectionId
    }

    fun selectScope(scopeId: Int) {
        _state.update { current ->
            if (current.scopes.any { it.id == scopeId }) current.copy(selectedScopeId = scopeId) else current
        }
    }

    fun setSearch(text: String) {
        _searchInput.value = text
    }

    fun refresh() {
        scopeReloads.value += 1
        refreshBooks()
    }

    fun refreshBooks() {
        val request = currentRequest() ?: return
        cancelBookLoads()
        val started = _books.updateAndGet { it.refresh() }
        firstPageJob = viewModelScope.launch { fetch(request, started.generation, FIRST_PAGE) }
    }

    fun loadMoreBooks() {
        val request = currentRequest() ?: return
        val loading = _books.value.beginNextPage() ?: return
        _books.value = loading
        nextPageJob = viewModelScope.launch { fetch(request, loading.generation, loading.nextPage) }
    }

    private suspend fun loadScopes(hasAccounts: Boolean, connectionId: String?) {
        if (!hasAccounts || connectionId == null) {
            _state.value = BookOrbitSmartScopesState(loading = false, noAccount = true)
            return
        }
        val retained = _state.value.takeIf { it.loadedAccountId == connectionId }
        _state.value = retained?.copy(loading = true, failure = null) ?: BookOrbitSmartScopesState()
        try {
            val scopes = bookOrbit.smartScopes(connectionId)
            _state.update { current ->
                if (scopes == null) {
                    BookOrbitSmartScopesState(loading = false, unsupported = true)
                } else {
                    BookOrbitSmartScopesState(
                        loading = false,
                        loadedAccountId = connectionId,
                        scopes = scopes,
                        selectedScopeId = current.selectedScopeId?.takeIf { id -> scopes.any { it.id == id } }
                            ?: scopes.firstOrNull()?.id,
                    )
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _state.update { it.copy(loading = false, failure = e.bookOrbitReason()) }
        }
    }

    private fun restartBooks(request: BooksRequest) {
        cancelBookLoads()
        _booksFailure.value = null
        if (request.connectionId == null || request.scopeId == null) {
            _books.update { it.cleared() }
            return
        }
        val started = _books.updateAndGet { it.restart() }
        firstPageJob = viewModelScope.launch { fetch(request, started.generation, FIRST_PAGE) }
    }

    private suspend fun fetch(request: BooksRequest, generation: Int, page: Int) {
        val connectionId = request.connectionId ?: return
        val scopeId = request.scopeId ?: return
        try {
            val result = bookOrbit.smartScopeBooks(connectionId, scopeId, page, request.search)
            if (_books.value.generation == generation) _booksFailure.value = null
            _books.update { it.receive(generation, page, result.books, result.total, Book::uniqueKey) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (_books.value.generation == generation) _booksFailure.value = e.bookOrbitReason()
            _books.update { it.fail(generation, page) }
        }
    }

    private fun currentRequest(): BooksRequest? {
        val current = _state.value
        val connectionId = current.loadedAccountId ?: return null
        val scopeId = current.selectedScopeId ?: return null
        return BooksRequest(connectionId, scopeId, appliedSearch.value)
    }

    private fun cancelBookLoads() {
        firstPageJob?.cancel()
        nextPageJob?.cancel()
    }

    private data class BooksRequest(
        val connectionId: String?,
        val scopeId: Int?,
        val search: String,
    )

    private companion object {
        const val SEARCH_DEBOUNCE_MS = 300L
        const val FIRST_PAGE = 0
    }
}
