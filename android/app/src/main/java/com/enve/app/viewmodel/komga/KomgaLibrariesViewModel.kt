package com.enve.app.viewmodel.komga

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.komga.dto.KomgaLibraryCreationDto
import com.enve.komga.dto.KomgaLibraryDto
import com.enve.komga.dto.KomgaLibraryUpdateDto
import com.enve.komga.KomgaRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class KomgaLibrariesState(
    val isLoading: Boolean = true,
    val libraries: List<KomgaLibraryDto> = emptyList(),
    val error: String? = null,
    val toast: String? = null,
)

@HiltViewModel
class KomgaLibrariesViewModel @Inject constructor(
    private val repository: KomgaRepository,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    private val connectionId: String = savedStateHandle.get<String>("connectionId").orEmpty()

    private val _state = MutableStateFlow(KomgaLibrariesState())
    val state: StateFlow<KomgaLibrariesState> = _state.asStateFlow()

    init { refresh() }

    fun refresh() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            withKomgaConnection(connectionId) {
                val libs = repository.fetchLibrariesRaw().getOrNull().orEmpty()
                _state.update { it.copy(isLoading = false, libraries = libs) }
            }
        }
    }

    fun consumeToast() = _state.update { it.copy(toast = null) }
    fun consumeError() = _state.update { it.copy(error = null) }

    fun createLibrary(name: String, root: String) {
        if (name.isBlank() || root.isBlank()) return
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminCreateLibrary(KomgaLibraryCreationDto(name = name, root = root))
                    .onSuccess { _state.update { it.copy(toast = "Library created") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }

    fun renameLibrary(id: String, name: String) {
        if (name.isBlank()) return
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminUpdateLibrary(id, KomgaLibraryUpdateDto(name = name))
                    .onSuccess { _state.update { it.copy(toast = "Library renamed") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }

    fun deleteLibrary(id: String) {
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminDeleteLibrary(id)
                    .onSuccess { _state.update { it.copy(toast = "Library deleted") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refresh()
        }
    }

    fun scan(id: String, deep: Boolean) = runAdmin("Scan started") {
        repository.adminScanLibrary(id, deep)
    }
    fun analyze(id: String) = runAdmin("Analyze started") { repository.adminAnalyzeLibrary(id) }
    fun refreshMetadata(id: String) = runAdmin("Metadata refresh queued") { repository.adminRefreshLibraryMetadata(id) }
    fun emptyTrash(id: String) = runAdmin("Trash emptied") { repository.adminEmptyLibraryTrash(id) }

    private fun runAdmin(successToast: String, block: suspend () -> Result<Unit>) {
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                block()
                    .onSuccess { _state.update { it.copy(toast = successToast) } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
        }
    }
}
