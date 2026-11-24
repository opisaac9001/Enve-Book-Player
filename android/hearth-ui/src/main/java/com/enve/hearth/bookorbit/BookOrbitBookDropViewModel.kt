package com.enve.hearth.bookorbit

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.engine.bookorbit.BookOrbitAccount
import com.enve.engine.bookorbit.BookOrbitBookDropAccess
import com.enve.engine.bookorbit.BookOrbitBookDropApproval
import com.enve.engine.bookorbit.BookOrbitBookDropEdit
import com.enve.engine.bookorbit.BookOrbitBookDropItem
import com.enve.engine.bookorbit.BookOrbitBookDropLibrary
import com.enve.engine.bookorbit.BookOrbitBookDropQuery
import com.enve.engine.bookorbit.BookOrbitBookDropStatus
import com.enve.engine.bookorbit.BookOrbitBookDropSummary
import com.enve.engine.bookorbit.BookOrbitFacade
import com.enve.engine.bookorbit.BookOrbitFailureReason
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

enum class BookOrbitBookDropPhase { LOADING, NO_ACCOUNT, DENIED, FAILED, READY }

enum class BookOrbitBookDropBusy { IMPORTING, SAVING, APPLYING, APPROVING, DISCARDING }

data class BookOrbitBookDropState(
    val phase: BookOrbitBookDropPhase = BookOrbitBookDropPhase.LOADING,
    val accountId: String? = null,
    val failure: BookOrbitFailureReason? = null,
    val access: BookOrbitBookDropAccess? = null,
    val summary: BookOrbitBookDropSummary? = null,
    val libraries: List<BookOrbitBookDropLibrary> = emptyList(),
    val librariesFailed: Boolean = false,
    val statusFilter: BookOrbitBookDropStatus? = null,
    val selection: Set<Int> = emptySet(),
    val busy: BookOrbitBookDropBusy? = null,
    val reviewId: Int? = null,
    val approval: BookOrbitBookDropApproval? = null,
    val notice: String? = null,
) {
    val canApprove: Boolean get() = access?.canApprove == true
}

internal fun BookOrbitBookDropState.afterAction(connectionId: String, latest: Boolean): BookOrbitBookDropState =
    if (latest && accountId == connectionId) copy(busy = null) else this

internal fun bookDropApprovalHeadline(approval: BookOrbitBookDropApproval): String = when {
    approval.total == 0 -> "Nothing was added"
    approval.failed == 0 -> if (approval.succeeded == 1) "Added to the library" else "Added ${approval.succeeded} books"
    approval.succeeded == 0 -> if (approval.failed == 1) "Not added" else "None of the ${approval.failed} files were added"
    else -> "Added ${approval.succeeded} of ${approval.total}"
}

@HiltViewModel
class BookOrbitBookDropViewModel @Inject constructor(
    private val bookOrbit: BookOrbitFacade,
) : ViewModel() {
    val accounts: StateFlow<List<BookOrbitAccount>> =
        bookOrbit.accounts.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val chosenAccountId = MutableStateFlow<String?>(null)
    private val reloads = MutableStateFlow(0)
    private val appliedSearch = MutableStateFlow("")

    val activeAccountId: StateFlow<String?> = combine(accounts, chosenAccountId) { available, chosen ->
        chosen?.takeIf { id -> available.any { it.connectionId == id } } ?: available.firstOrNull()?.connectionId
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    private val _state = MutableStateFlow(BookOrbitBookDropState())
    val state: StateFlow<BookOrbitBookDropState> = _state.asStateFlow()

    private val _searchInput = MutableStateFlow("")
    val searchInput: StateFlow<String> = _searchInput.asStateFlow()

    private val _items = MutableStateFlow(BookOrbitPagedList<BookOrbitBookDropItem>(firstPage = FIRST_PAGE))
    val items: StateFlow<BookOrbitPagedList<BookOrbitBookDropItem>> = _items.asStateFlow()

    private val _itemsFailure = MutableStateFlow<BookOrbitFailureReason?>(null)
    val itemsFailure: StateFlow<BookOrbitFailureReason?> = _itemsFailure.asStateFlow()

    private var firstPageJob: Job? = null
    private var nextPageJob: Job? = null
    private var actionSerial = 0

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
            combine(accounts, activeAccountId, reloads) { available, id, reload ->
                Triple(available.isNotEmpty(), id, reload)
            }.distinctUntilChanged().collectLatest { (hasAccounts, connectionId, _) ->
                open(hasAccounts, connectionId)
            }
        }
        viewModelScope.launch {
            combine(_state, appliedSearch) { current, search ->
                ItemsRequest(
                    connectionId = current.accountId.takeIf { current.phase == BookOrbitBookDropPhase.READY },
                    status = current.statusFilter,
                    search = search,
                )
            }.distinctUntilChanged().collect(::restartItems)
        }
    }

    fun selectAccount(connectionId: String) {
        chosenAccountId.value = connectionId
    }

    fun retry() {
        reloads.value += 1
    }

    fun setSearch(text: String) {
        _searchInput.value = text
    }

    fun setStatusFilter(status: BookOrbitBookDropStatus?) {
        _state.update { it.copy(statusFilter = status, selection = emptySet()) }
    }

    fun toggleSelected(itemId: Int) {
        _state.update { current ->
            current.copy(selection = if (itemId in current.selection) current.selection - itemId else current.selection + itemId)
        }
    }

    fun clearSelection() {
        _state.update { it.copy(selection = emptySet()) }
    }

    fun openReview(itemId: Int) {
        _state.update { it.copy(reviewId = itemId) }
    }

    fun closeReview() {
        _state.update { it.copy(reviewId = null) }
    }

    fun dismissNotice() {
        _state.update { it.copy(notice = null) }
    }

    fun dismissApproval() {
        _state.update { it.copy(approval = null) }
    }

    fun refresh() {
        val request = currentRequest() ?: return
        cancelItemLoads()
        val started = _items.updateAndGet { it.refresh() }
        firstPageJob = viewModelScope.launch {
            fetch(request, started.generation, FIRST_PAGE)
            refreshSummary(checkNotNull(request.connectionId))
        }
    }

    fun loadMore() {
        val request = currentRequest() ?: return
        val loading = _items.value.beginNextPage() ?: return
        _items.value = loading
        nextPageJob = viewModelScope.launch { fetch(request, loading.generation, loading.nextPage) }
    }

    fun importFile(contentUri: String) = act(BookOrbitBookDropBusy.IMPORTING, "import that file") { connectionId ->
        val imported = bookOrbit.importBookDropFile(connectionId, contentUri)
        afterMutation(connectionId, "Imported ${imported.fileName}. BookOrbit is reading its details.")
    }

    fun save(itemId: Int, edit: BookOrbitBookDropEdit) = act(BookOrbitBookDropBusy.SAVING, "save those changes") { connectionId ->
        val updated = bookOrbit.updateBookDropItem(connectionId, itemId, edit)
        replace(connectionId, updated)
        notify(connectionId, "Saved changes to ${updated.fileName}.")
    }

    fun applyFetched(itemIds: List<Int>) = act(BookOrbitBookDropBusy.APPLYING, "apply the fetched details") { connectionId ->
        val result = bookOrbit.applyFetchedBookDropMetadata(connectionId, itemIds)
        val kept = result.skippedEdited + result.skipped
        afterMutation(
            connectionId,
            when {
                result.applied == 0 && result.skippedEdited > 0 -> "Nothing applied. Your own edits were kept."
                result.applied == 0 -> "Nothing to apply. No fetched details were waiting."
                kept > 0 -> "Applied fetched details to ${result.applied}; $kept left unchanged."
                result.applied == 1 -> "Applied the fetched details."
                else -> "Applied fetched details to ${result.applied} files."
            },
        )
    }

    fun approve(itemIds: List<Int>, edit: Pair<Int, BookOrbitBookDropEdit>? = null) =
        act(BookOrbitBookDropBusy.APPROVING, "add those files to the library") { connectionId ->
            edit?.let { (itemId, changes) -> replace(connectionId, bookOrbit.updateBookDropItem(connectionId, itemId, changes)) }
            val approval = bookOrbit.approveBookDropItems(connectionId, itemIds)
            val added = approval.results.filter { it.success }.mapTo(mutableSetOf()) { it.fileId }
            _state.update { current ->
                if (current.accountId != connectionId) current
                else current.copy(
                    approval = approval,
                    selection = current.selection - added,
                    reviewId = current.reviewId?.takeIf { it !in added },
                )
            }
            afterMutation(connectionId, notice = null)
        }

    fun discard(itemIds: List<Int>) = act(BookOrbitBookDropBusy.DISCARDING, "discard those files") { connectionId ->
        bookOrbit.discardBookDropItems(connectionId, itemIds)
        val discarded = itemIds.toSet()
        _state.update { current ->
            if (current.accountId != connectionId) current
            else current.copy(
                selection = current.selection - discarded,
                reviewId = current.reviewId?.takeIf { it !in discarded },
            )
        }
        afterMutation(connectionId, if (discarded.size == 1) "Discarded 1 file." else "Discarded ${discarded.size} files.")
    }

    private fun act(busy: BookOrbitBookDropBusy, action: String, block: suspend (String) -> Unit) {
        val current = _state.value
        val connectionId = current.accountId ?: return
        if (current.phase != BookOrbitBookDropPhase.READY || current.busy != null) return
        val serial = ++actionSerial
        _state.update { it.copy(busy = busy, notice = null) }
        viewModelScope.launch {
            try {
                block(connectionId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                notify(connectionId, bookOrbitActionFailure(action, e))
            } finally {
                _state.update { it.afterAction(connectionId, latest = actionSerial == serial) }
            }
        }
    }

    private suspend fun open(hasAccounts: Boolean, connectionId: String?) {
        cancelItemLoads()
        if (!hasAccounts || connectionId == null) {
            _state.value = BookOrbitBookDropState(phase = BookOrbitBookDropPhase.NO_ACCOUNT)
            return
        }
        _state.value = BookOrbitBookDropState(accountId = connectionId)
        try {
            val access = bookOrbit.bookDropAccess(connectionId)
            if (!access.canView) {
                _state.value = BookOrbitBookDropState(
                    phase = BookOrbitBookDropPhase.DENIED,
                    accountId = connectionId,
                    access = access,
                )
                return
            }
            _state.value = BookOrbitBookDropState(
                phase = BookOrbitBookDropPhase.READY,
                accountId = connectionId,
                access = access,
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val reason = e.bookOrbitReason()
            _state.value = BookOrbitBookDropState(
                phase = if (reason == BookOrbitFailureReason.FORBIDDEN) BookOrbitBookDropPhase.DENIED else BookOrbitBookDropPhase.FAILED,
                accountId = connectionId,
                failure = reason,
            )
            return
        }
        refreshSummary(connectionId)
        loadLibraries(connectionId)
    }

    fun loadLibraries() {
        val connectionId = _state.value.accountId ?: return
        viewModelScope.launch { loadLibraries(connectionId) }
    }

    private suspend fun loadLibraries(connectionId: String) {
        try {
            val libraries = bookOrbit.bookDropLibraries(connectionId)
            _state.update { if (it.accountId == connectionId) it.copy(libraries = libraries, librariesFailed = false) else it }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            _state.update { if (it.accountId == connectionId) it.copy(librariesFailed = true) else it }
        }
    }

    private suspend fun refreshSummary(connectionId: String) {
        try {
            val summary = bookOrbit.bookDropSummary(connectionId)
            _state.update { if (it.accountId == connectionId) it.copy(summary = summary) else it }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            _state.update { if (it.accountId == connectionId) it.copy(summary = null) else it }
        }
    }

    private suspend fun afterMutation(connectionId: String, notice: String?) {
        notice?.let { notify(connectionId, it) }
        val request = currentRequest()?.takeIf { it.connectionId == connectionId } ?: return
        cancelItemLoads()
        val started = _items.updateAndGet { it.refresh() }
        fetch(request, started.generation, FIRST_PAGE)
        refreshSummary(connectionId)
    }

    private fun notify(connectionId: String, message: String) {
        _state.update { if (it.accountId == connectionId) it.copy(notice = message) else it }
    }

    private fun replace(connectionId: String, item: BookOrbitBookDropItem) {
        if (_state.value.accountId == connectionId) _items.update { it.replacing({ row -> row.id == item.id }, item) }
    }

    private fun restartItems(request: ItemsRequest) {
        cancelItemLoads()
        _itemsFailure.value = null
        if (request.connectionId == null) {
            _items.update { it.cleared() }
            return
        }
        val started = _items.updateAndGet { it.restart() }
        firstPageJob = viewModelScope.launch { fetch(request, started.generation, FIRST_PAGE) }
    }

    private suspend fun fetch(request: ItemsRequest, generation: Int, page: Int) {
        val connectionId = request.connectionId ?: return
        try {
            val result = bookOrbit.bookDropItems(
                connectionId,
                BookOrbitBookDropQuery(page = page, status = request.status, search = request.search),
            )
            if (_items.value.generation == generation) _itemsFailure.value = null
            _items.update { it.receive(generation, page, result.items, result.total, BookOrbitBookDropItem::id) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (_items.value.generation == generation) _itemsFailure.value = e.bookOrbitReason()
            _items.update { it.fail(generation, page) }
        }
    }

    private fun currentRequest(): ItemsRequest? {
        val current = _state.value
        if (current.phase != BookOrbitBookDropPhase.READY) return null
        val connectionId = current.accountId ?: return null
        return ItemsRequest(connectionId, current.statusFilter, appliedSearch.value)
    }

    private fun cancelItemLoads() {
        firstPageJob?.cancel()
        nextPageJob?.cancel()
    }

    private data class ItemsRequest(
        val connectionId: String?,
        val status: BookOrbitBookDropStatus?,
        val search: String,
    )

    private companion object {
        const val SEARCH_DEBOUNCE_MS = 300L
        const val FIRST_PAGE = 1
    }
}
