package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.data.hardcover.HardcoverActivity
import com.enve.app.data.hardcover.HardcoverBookResult
import com.enve.app.data.hardcover.HardcoverLibraryBook
import com.enve.app.data.hardcover.HardcoverProfile
import com.enve.app.data.hardcover.HardcoverReadingGoal
import com.enve.app.data.hardcover.HardcoverService
import com.enve.app.data.hardcover.HardcoverUserList
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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
    val searchQuery: String = "",
    val searchResults: List<HardcoverBookResult> = emptyList(),
    val isLoading: Boolean = false,
    val isSearching: Boolean = false,
    val isSavingToken: Boolean = false,
    val error: String? = null,
    val message: String? = null,
)

@HiltViewModel
class HardcoverHubViewModel @Inject constructor(
    private val service: HardcoverService,
) : ViewModel() {
    private val _state = MutableStateFlow(HardcoverHubState(hasToken = service.hasToken()))
    val state: StateFlow<HardcoverHubState> = _state.asStateFlow()

    private var searchJob: Job? = null

    fun load() {
        if (!service.hasToken()) {
            _state.update { it.copy(hasToken = false, isLoading = false) }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(hasToken = true, isLoading = true, error = null) }
            runCatching { service.loadHubData() }
                .onSuccess { data ->
                    _state.update {
                        it.copy(
                            hasToken = true,
                            profile = data.profile,
                            library = data.library,
                            lists = data.lists,
                            activity = data.activity,
                            readingGoal = data.readingGoal,
                            goalInput = data.readingGoal?.target?.toString().orEmpty(),
                            isLoading = false,
                            error = null,
                        )
                    }
                }
                .onFailure { error ->
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
        viewModelScope.launch {
            _state.update { it.copy(isSavingToken = true, error = null, message = null) }
            runCatching { service.saveToken(token) }
                .onSuccess { profile ->
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
                }
                .onFailure { error ->
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
        service.clearToken()
        _state.value = HardcoverHubState()
    }

    fun updateSearchQuery(value: String) {
        _state.update { it.copy(searchQuery = value) }
        searchJob?.cancel()
        if (value.trim().length < 2) {
            _state.update { it.copy(searchResults = emptyList(), isSearching = false) }
            return
        }
        searchJob = viewModelScope.launch {
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
        viewModelScope.launch {
            _state.update { it.copy(message = null, error = null) }
            runCatching { service.addBookToLibrary(book.id, startReading) }
                .onSuccess {
                    _state.update { it.copy(message = "Added ${book.title} to Hardcover") }
                    load()
                }
                .onFailure { error ->
                    _state.update { it.copy(error = error.message ?: "Couldn't add book to Hardcover.") }
                }
        }
    }

    fun updateGoalInput(value: String) {
        _state.update { it.copy(goalInput = value.filter { ch -> ch.isDigit() }) }
    }

    fun saveReadingGoal() {
        val target = _state.value.goalInput.toIntOrNull() ?: return
        viewModelScope.launch {
            _state.update { it.copy(message = null, error = null) }
            runCatching { service.setReadingGoal(target) }
                .onSuccess {
                    _state.update { it.copy(message = "Reading goal updated") }
                    load()
                }
                .onFailure { error ->
                    _state.update { it.copy(error = error.message ?: "Couldn't update reading goal.") }
                }
        }
    }

    fun clearTransientMessage() {
        _state.update { it.copy(error = null, message = null) }
    }
}
