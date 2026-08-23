package com.enve.app.viewmodel.komga

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.komga.dto.KomgaCollectionCreationDto
import com.enve.komga.dto.KomgaCollectionDto
import com.enve.komga.dto.KomgaCollectionUpdateDto
import com.enve.komga.KomgaRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class KomgaCollectionsState(
    val isLoading: Boolean = true,
    val collections: List<KomgaCollectionDto> = emptyList(),
    val error: String? = null,
    val toast: String? = null,
)

@HiltViewModel
class KomgaCollectionsViewModel @Inject constructor(
    private val repository: KomgaRepository,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    private val connectionId: String = savedStateHandle.get<String>("connectionId").orEmpty()

    private val _state = MutableStateFlow(KomgaCollectionsState())
    val state: StateFlow<KomgaCollectionsState> = _state.asStateFlow()

    init { refresh() }

    fun refresh() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            withKomgaConnection(connectionId) {
                val resp = repository.fetchCollectionsRaw().getOrNull().orEmpty()
                _state.update { it.copy(isLoading = false, collections = resp) }
            }
        }
    }

    fun consumeToast() = _state.update { it.copy(toast = null) }
    fun consumeError() = _state.update { it.copy(error = null) }

    fun create(name: String, ordered: Boolean) {
        if (name.isBlank()) return
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminCreateCollection(KomgaCollectionCreationDto(name = name, ordered = ordered))
                    .onSuccess { _state.update { it.copy(toast = "Collection created") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }

    fun rename(id: String, name: String) {
        if (name.isBlank()) return
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminUpdateCollection(id, KomgaCollectionUpdateDto(name = name))
                    .onSuccess { _state.update { it.copy(toast = "Renamed") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }

    fun delete(id: String) {
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminDeleteCollection(id)
                    .onSuccess { _state.update { it.copy(toast = "Deleted") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }
}
