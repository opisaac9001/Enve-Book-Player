package com.enve.app.viewmodel

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import com.enve.storyteller.StorytellerHubRepository
import com.enve.storyteller.StorytellerProcessRestart
import com.enve.storyteller.storytellerProcessCandidates
import com.enve.storyteller.dto.StorytellerAlignmentFacetsDto
import com.enve.storyteller.dto.StorytellerAlignmentReportDto
import com.enve.storyteller.dto.StorytellerBookDto
import com.enve.storyteller.dto.StorytellerShelfDto
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class StorytellerHubState(
    val connections: List<ProviderConnection> = emptyList(),
    val selectedConnectionId: String? = null,
    val isLoading: Boolean = false,
    val loaded: Boolean = false,
    val shelves: List<StorytellerShelfDto> = emptyList(),
    val shelvesError: String? = null,
    val facets: StorytellerAlignmentFacetsDto? = null,
    val books: List<StorytellerBookDto> = emptyList(),
    val alignmentError: String? = null,
    val processingError: String? = null,
    val report: StorytellerAlignmentReportDto? = null,
    val reportLoading: Boolean = false,
    val busyShelfId: String? = null,
    val busyBookId: String? = null,
    val message: String? = null,
) {
    val storytellerConnections: List<ProviderConnection>
        get() = connections.filter { it.source == BookSource.STORYTELLER && it.enabled }

    val selectedConnection: ProviderConnection?
        get() = storytellerConnections.firstOrNull { it.id == selectedConnectionId }
            ?: storytellerConnections.firstOrNull()

    val candidates: List<StorytellerBookDto>
        get() = storytellerProcessCandidates(books)
}

@HiltViewModel
class StorytellerHubViewModel @Inject constructor(
    connectionRegistry: ConnectionRegistry,
    private val hubRepository: StorytellerHubRepository,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {
    private var refreshJob: Job? = null
    private var processingRefreshJob: Job? = null
    private val localState = MutableStateFlow(
        StorytellerHubState(selectedConnectionId = savedStateHandle["connectionId"]),
    )

    val state: StateFlow<StorytellerHubState> = combine(
        connectionRegistry.connections,
        localState,
    ) { connections, local ->
        val available = connections.filter { it.source == BookSource.STORYTELLER && it.enabled }
        val selected = local.selectedConnectionId?.takeIf { id -> available.any { it.id == id } }
            ?: available.firstOrNull()?.id
        local.copy(connections = connections, selectedConnectionId = selected)
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = localState.value,
    )

    init {
        viewModelScope.launch {
            state.collect { current ->
                if (!current.loaded && !current.isLoading && current.selectedConnection != null) {
                    refresh()
                }
            }
        }
    }

    fun selectConnection(connectionId: String) {
        refreshJob?.cancel()
        processingRefreshJob?.cancel()
        localState.update {
            it.copy(
                selectedConnectionId = connectionId,
                isLoading = false,
                loaded = false,
                shelves = emptyList(),
                shelvesError = null,
                facets = null,
                books = emptyList(),
                alignmentError = null,
                processingError = null,
                report = null,
                reportLoading = false,
                busyShelfId = null,
                busyBookId = null,
                message = null,
            )
        }
    }

    fun refresh() {
        if (state.value.isLoading) return
        val connection = state.value.selectedConnection ?: return
        refreshJob = viewModelScope.launch {
            localState.update {
                it.copy(
                    selectedConnectionId = connection.id,
                    isLoading = true,
                    loaded = true,
                    message = null,
                )
            }
            try {
                val (shelves, facets, books) = scoped(connection) {
                    coroutineScope {
                        val shelves = async { hubRepository.getShelves() }
                        val facets = async { hubRepository.getAlignmentFacets() }
                        val books = async { hubRepository.getBooks() }
                        Triple(shelves.await(), facets.await(), books.await())
                    }
                }
                if (!isSelected(connection)) return@launch
                localState.update { current ->
                    current.copy(
                        shelves = shelves.getOrDefault(current.shelves),
                        shelvesError = shelves.exceptionOrNull()?.message,
                        facets = facets.getOrNull() ?: current.facets,
                        books = books.getOrDefault(current.books),
                        alignmentError = facets.exceptionOrNull()?.message,
                        processingError = books.exceptionOrNull()?.message,
                    )
                }
            } finally {
                if (isSelected(connection)) {
                    localState.update { it.copy(isLoading = false) }
                }
            }
        }
    }

    fun createShelf(name: String, description: String?) {
        val trimmed = name.trim()
        if (trimmed.isBlank()) return
        mutateShelves("create", "Shelf created") {
            hubRepository.createShelf(trimmed, description?.trim()?.takeIf { it.isNotBlank() })
        }
    }

    fun renameShelf(shelf: StorytellerShelfDto, name: String) {
        val trimmed = name.trim()
        if (trimmed.isBlank() || trimmed == shelf.name) return
        mutateShelves(shelf.uuid, "Shelf renamed") { hubRepository.updateShelf(shelf, trimmed) }
    }

    fun deleteShelf(shelf: StorytellerShelfDto) {
        mutateShelves(shelf.uuid, "Shelf deleted") { hubRepository.deleteShelf(shelf.uuid) }
    }

    fun updateShelfBooks(shelf: StorytellerShelfDto, bookIds: List<String>) {
        val currentIds = shelf.books.orEmpty().map { it.bookUuid }
        if (currentIds == bookIds) return
        mutateShelves(shelf.uuid, "Shelf books saved") {
            hubRepository.updateShelfBooks(shelf.uuid, bookIds)
        }
    }

    private fun mutateShelves(
        shelfId: String,
        successMessage: String,
        operation: suspend () -> Result<Unit>,
    ) {
        val connection = state.value.selectedConnection ?: return
        if (state.value.busyShelfId != null) return
        viewModelScope.launch {
            localState.update { it.copy(busyShelfId = shelfId, message = null) }
            val result = scoped(connection) { operation() }
            if (!isSelected(connection)) return@launch
            result.onFailure { error ->
                localState.update {
                    it.copy(
                        busyShelfId = null,
                        message = error.message ?: "Storyteller shelf update failed",
                    )
                }
                return@launch
            }
            val shelves = scoped(connection) { hubRepository.getShelves() }
            if (!isSelected(connection)) return@launch
            localState.update { current ->
                current.copy(
                    busyShelfId = null,
                    shelves = shelves.getOrDefault(current.shelves),
                    shelvesError = shelves.exceptionOrNull()?.message,
                    message = if (shelves.isSuccess) successMessage else shelves.exceptionOrNull()?.message,
                )
            }
        }
    }

    fun openReport(bookId: String) {
        val connection = state.value.selectedConnection ?: return
        viewModelScope.launch {
            localState.update { it.copy(reportLoading = true, report = null, message = null) }
            val result = scoped(connection) { hubRepository.getAlignmentReport(bookId) }
            if (!isSelected(connection)) return@launch
            localState.update { current ->
                current.copy(
                    reportLoading = false,
                    report = result.getOrNull(),
                    message = result.exceptionOrNull()?.message,
                )
            }
        }
    }

    fun closeReport() {
        localState.update { it.copy(report = null, reportLoading = false) }
    }

    fun startProcessing(bookId: String, restart: StorytellerProcessRestart?) {
        runProcessAction(bookId) { hubRepository.startProcessing(bookId, restart) }
    }

    fun cancelProcessing(bookId: String) {
        runProcessAction(bookId) { hubRepository.cancelProcessing(bookId) }
    }

    private fun runProcessAction(bookId: String, action: suspend () -> Result<Unit>) {
        val connection = state.value.selectedConnection ?: return
        if (state.value.busyBookId != null) return
        viewModelScope.launch {
            localState.update { it.copy(busyBookId = bookId, message = null) }
            val result = scoped(connection) { action() }
            if (!isSelected(connection)) return@launch
            result.onFailure { error ->
                localState.update {
                    it.copy(busyBookId = null, message = error.message ?: "Storyteller processing request failed")
                }
                return@launch
            }
            delay(1_000)
            val (books, facets) = fetchProcessingData(connection)
            if (!isSelected(connection)) return@launch
            localState.update { current ->
                current.copy(
                    busyBookId = null,
                    books = books.getOrDefault(current.books),
                    facets = facets.getOrNull() ?: current.facets,
                    alignmentError = facets.exceptionOrNull()?.message,
                    processingError = books.exceptionOrNull()?.message,
                )
            }
        }
    }

    fun refreshProcessing() {
        val connection = state.value.selectedConnection ?: return
        if (state.value.isLoading || state.value.busyBookId != null || processingRefreshJob?.isActive == true) return
        processingRefreshJob = viewModelScope.launch {
            val (books, facets) = fetchProcessingData(connection)
            if (!isSelected(connection)) return@launch
            localState.update { current ->
                current.copy(
                    books = books.getOrDefault(current.books),
                    facets = facets.getOrNull() ?: current.facets,
                    alignmentError = facets.exceptionOrNull()?.message,
                    processingError = books.exceptionOrNull()?.message,
                )
            }
        }
    }

    private suspend fun fetchProcessingData(
        connection: ProviderConnection,
    ): Pair<Result<List<StorytellerBookDto>>, Result<StorytellerAlignmentFacetsDto>> = scoped(connection) {
        coroutineScope {
            val books = async { hubRepository.getBooks() }
            val facets = async { hubRepository.getAlignmentFacets() }
            books.await() to facets.await()
        }
    }

    fun clearMessage() {
        localState.update { it.copy(message = null) }
    }

    private suspend fun <T> scoped(connection: ProviderConnection, block: suspend () -> T): T =
        withContext(ConnectionScope.asContextElement(connection.id)) { block() }

    private fun isSelected(connection: ProviderConnection): Boolean =
        state.value.selectedConnection?.id == connection.id
}
