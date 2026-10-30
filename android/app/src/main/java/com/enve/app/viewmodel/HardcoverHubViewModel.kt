package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.data.hardcover.HardcoverActivity
import com.enve.app.data.hardcover.HardcoverBookMatch
import com.enve.app.data.hardcover.HardcoverBookResult
import com.enve.app.data.hardcover.HardcoverLibraryBook
import com.enve.app.data.hardcover.HardcoverProfile
import com.enve.app.data.hardcover.HardcoverQueueSummary
import com.enve.app.data.hardcover.HardcoverReadingGoal
import com.enve.app.data.hardcover.HardcoverService
import com.enve.app.data.hardcover.HardcoverSyncService
import com.enve.app.data.hardcover.HardcoverSyncStatus
import com.enve.app.data.hardcover.HardcoverUserList
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.engine.library.LibraryFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class HardcoverHubState(
    val hasToken: Boolean = false,
    val tokenInput: String = "",
    val goalInput: String = "",
    val profile: HardcoverProfile? = null,
    val library: List<HardcoverLibraryBook> = emptyList(),
    val lists: List<HardcoverUserList> = emptyList(),
    val activity: List<HardcoverActivity> = emptyList(),
    val readingGoal: HardcoverReadingGoal? = null,
    val listsError: String? = null,
    val activityError: String? = null,
    val goalError: String? = null,
    val searchQuery: String = "",
    val searchResults: List<HardcoverBookResult> = emptyList(),
    val isLoading: Boolean = false,
    val isSearching: Boolean = false,
    val isSavingToken: Boolean = false,
    val syncEnabled: Boolean = false,
    val syncStatus: HardcoverSyncStatus? = null,
    val queue: HardcoverQueueSummary = HardcoverQueueSummary(),
    val matches: List<HardcoverBookMatch> = emptyList(),
    val linkTarget: HardcoverBookResult? = null,
    val localQuery: String = "",
    val localResults: List<Book> = emptyList(),
    val error: String? = null,
    val message: String? = null,
)

@HiltViewModel
class HardcoverHubViewModel @Inject constructor(
    private val service: HardcoverService,
    private val sync: HardcoverSyncService,
    private val library: LibraryFacade,
) : ViewModel() {
    private val _state = MutableStateFlow(HardcoverHubState(hasToken = service.hasToken()))
    val state: StateFlow<HardcoverHubState> = _state.asStateFlow()

    private var accountScope = newAccountScope()
    private var loadJob: Job? = null
    private var searchJob: Job? = null
    private var localSearchJob: Job? = null

    init {
        viewModelScope.launch {
            combine(sync.enabled, sync.status, sync.queue, sync.matches) { enabled, status, queue, matches ->
                val sortedMatches = matches.values.sortedBy { it.localTitle.lowercase() }
                _state.update { it.copy(syncEnabled = enabled, syncStatus = status, queue = queue, matches = sortedMatches) }
            }.collect()
        }
    }

    fun load() {
        if (!service.hasToken()) {
            _state.update { it.copy(hasToken = false, isLoading = false) }
            return
        }
        loadJob?.cancel()
        loadJob = accountScope.launch {
            _state.update { it.copy(hasToken = true, isLoading = true, error = null) }
            try {
                val data = service.loadHubData()
                _state.update {
                    it.copy(
                        hasToken = true,
                        profile = data.profile,
                        library = data.library,
                        lists = data.lists,
                        activity = data.activity,
                        readingGoal = data.readingGoal,
                        listsError = data.listsError,
                        activityError = data.activityError,
                        goalError = data.goalError,
                        goalInput = data.readingGoal?.target?.toString().orEmpty(),
                        isLoading = false,
                        error = null,
                    )
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update {
                    it.copy(
                        hasToken = service.hasToken(),
                        isLoading = false,
                        error = error.message ?: "Couldn't load Hardcover.",
                    )
                }
            }
        }
    }

    fun updateTokenInput(value: String) {
        _state.update { it.copy(tokenInput = value) }
    }

    fun saveToken() {
        val token = _state.value.tokenInput
        accountScope.launch {
            _state.update { it.copy(isSavingToken = true, error = null, message = null) }
            try {
                sync.resetAccount()
                val profile = service.saveToken(token)
                sync.start()
                _state.update {
                    it.copy(
                        hasToken = true,
                        tokenInput = "",
                        profile = profile,
                        isSavingToken = false,
                        message = "Connected to Hardcover",
                    )
                }
                load()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update {
                    it.copy(
                        hasToken = service.hasToken(),
                        isSavingToken = false,
                        error = error.message ?: "Couldn't connect to Hardcover.",
                    )
                }
            }
        }
    }

    fun disconnect() {
        accountScope.cancel()
        localSearchJob?.cancel()
        accountScope = newAccountScope()
        sync.disconnect()
        _state.update { HardcoverHubState(matches = it.matches) }
    }

    fun setSyncEnabled(enabled: Boolean) {
        sync.setEnabled(enabled)
    }

    fun updateSearchQuery(value: String) {
        _state.update { it.copy(searchQuery = value) }
        searchJob?.cancel()
        if (value.trim().length < 2) {
            _state.update { it.copy(searchResults = emptyList(), isSearching = false) }
            return
        }
        searchJob = accountScope.launch {
            _state.update { it.copy(isSearching = true, error = null) }
            try {
                val results = service.searchBooks(value)
                _state.update { it.copy(searchResults = results, isSearching = false) }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update {
                    it.copy(
                        searchResults = emptyList(),
                        isSearching = false,
                        error = error.message ?: "Hardcover search failed.",
                    )
                }
            }
        }
    }

    fun addToLibrary(book: HardcoverBookResult, startReading: Boolean = false) {
        accountScope.launch {
            _state.update { it.copy(message = null, error = null) }
            try {
                service.addBookToLibrary(book.id, startReading)
                _state.update { it.copy(message = "Added ${book.title} to Hardcover") }
                load()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update { it.copy(error = error.message ?: "Couldn't add book to Hardcover.") }
            }
        }
    }

    fun beginLink(book: HardcoverBookResult) {
        _state.update { it.copy(linkTarget = book) }
        updateLocalQuery(book.title)
    }

    fun cancelLink() {
        localSearchJob?.cancel()
        _state.update { it.copy(linkTarget = null, localQuery = "", localResults = emptyList()) }
    }

    fun updateLocalQuery(value: String) {
        _state.update { it.copy(localQuery = value) }
        localSearchJob?.cancel()
        val query = value.trim()
        if (query.length < 2) {
            _state.update { it.copy(localResults = emptyList()) }
            return
        }
        localSearchJob = viewModelScope.launch {
            val results = library.allBooks.first()
                .filter { book ->
                    book.mediaType != AppMediaType.PODCAST && (
                        book.title.contains(query, ignoreCase = true) ||
                            book.author.orEmpty().contains(query, ignoreCase = true)
                        )
                }
                .take(LOCAL_RESULT_LIMIT)
            _state.update { it.copy(localResults = results) }
        }
    }

    fun confirmLink(book: Book) {
        val target = _state.value.linkTarget ?: return
        sync.confirmMatch(book, target)
        cancelLink()
        _state.update { it.copy(message = "Linked ${book.title} to ${target.title} on Hardcover") }
    }

    fun unlink(localKey: String) {
        sync.unlink(localKey)
    }

    fun retryFailedSync() {
        sync.retryFailed()
    }

    fun discardFailedSync() {
        sync.discardFailed()
    }

    fun updateGoalInput(value: String) {
        _state.update { it.copy(goalInput = value.filter { ch -> ch.isDigit() }) }
    }

    fun saveReadingGoal() {
        val target = _state.value.goalInput.toIntOrNull() ?: return
        accountScope.launch {
            _state.update { it.copy(message = null, error = null) }
            try {
                service.setReadingGoal(target)
                _state.update { it.copy(message = "Reading goal updated") }
                load()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update { it.copy(error = error.message ?: "Couldn't update reading goal.") }
            }
        }
    }

    fun clearTransientMessage() {
        _state.update { it.copy(error = null, message = null) }
    }

    private fun newAccountScope(): CoroutineScope =
        CoroutineScope(viewModelScope.coroutineContext + SupervisorJob(viewModelScope.coroutineContext[Job]))

    private companion object {
        const val LOCAL_RESULT_LIMIT = 20
    }
}
