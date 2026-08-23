package com.enve.app.viewmodel.komga

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.komga.dto.KomgaReadListCreationDto
import com.enve.komga.dto.KomgaReadListDto
import com.enve.komga.dto.KomgaReadListUpdateDto
import com.enve.komga.KomgaRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class KomgaReadListsState(
    val isLoading: Boolean = true,
    val readLists: List<KomgaReadListDto> = emptyList(),
    val error: String? = null,
    val toast: String? = null,
)

@HiltViewModel
class KomgaReadListsViewModel @Inject constructor(
    private val repository: KomgaRepository,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    private val connectionId: String = savedStateHandle.get<String>("connectionId").orEmpty()

    private val _state = MutableStateFlow(KomgaReadListsState())
    val state: StateFlow<KomgaReadListsState> = _state.asStateFlow()

    init { refresh() }

    fun refresh() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            withKomgaConnection(connectionId) {
                val resp = repository.fetchReadListsRaw().getOrNull().orEmpty()
                _state.update { it.copy(isLoading = false, readLists = resp) }
            }
        }
    }

    fun consumeToast() = _state.update { it.copy(toast = null) }
    fun consumeError() = _state.update { it.copy(error = null) }

    fun create(name: String, summary: String) {
        if (name.isBlank()) return
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminCreateReadList(KomgaReadListCreationDto(name = name, summary = summary.takeIf { it.isNotBlank() }))
                    .onSuccess { _state.update { it.copy(toast = "Read list created") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }

    fun rename(id: String, name: String) {
        if (name.isBlank()) return
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminUpdateReadList(id, KomgaReadListUpdateDto(name = name))
                    .onSuccess { _state.update { it.copy(toast = "Renamed") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }

    fun delete(id: String) {
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminDeleteReadList(id)
                    .onSuccess { _state.update { it.copy(toast = "Deleted") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }
}
