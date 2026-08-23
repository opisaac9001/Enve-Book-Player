package com.enve.app.viewmodel.komga

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.komga.dto.KomgaActuatorInfoDto
import com.enve.komga.dto.KomgaAnnouncementsDto
import com.enve.komga.dto.KomgaApiKeyDto
import com.enve.komga.dto.KomgaHistoryEventDto
import com.enve.komga.dto.KomgaTaskDto
import com.enve.komga.KomgaRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class KomgaServerState(
    val isLoading: Boolean = true,
    val info: KomgaActuatorInfoDto? = null,
    val tasks: List<KomgaTaskDto> = emptyList(),
    val announcements: KomgaAnnouncementsDto? = null,
    val history: List<KomgaHistoryEventDto> = emptyList(),
    val apiKeys: List<KomgaApiKeyDto> = emptyList(),
    val newlyCreatedKey: KomgaApiKeyDto? = null,
    val error: String? = null,
    val toast: String? = null,
)

@HiltViewModel
class KomgaServerViewModel @Inject constructor(
    private val repository: KomgaRepository,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    private val connectionId: String = savedStateHandle.get<String>("connectionId").orEmpty()

    private val _state = MutableStateFlow(KomgaServerState())
    val state: StateFlow<KomgaServerState> = _state.asStateFlow()

    init {
        refreshAll()
    }

    fun refreshAll() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            withKomgaConnection(connectionId) {
                val info = repository.adminServerInfo().getOrNull()
                val tasks = repository.adminListTasks().getOrNull().orEmpty()
                val announcements = repository.adminListAnnouncements().getOrNull()
                val history = repository.adminListHistory().getOrNull()?.content.orEmpty()
                val apiKeys = repository.adminListApiKeys().getOrNull().orEmpty()
                _state.update {
                    it.copy(
                        isLoading = false,
                        info = info,
                        tasks = tasks,
                        announcements = announcements,
                        history = history,
                        apiKeys = apiKeys,
                    )
                }
            }
        }
    }

    fun consumeToast() = _state.update { it.copy(toast = null) }
    fun consumeError() = _state.update { it.copy(error = null) }
    fun consumeNewKey() = _state.update { it.copy(newlyCreatedKey = null) }

    fun markAnnouncementsRead(ids: List<String>) {
        if (ids.isEmpty()) return
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminMarkAnnouncementsRead(ids)
                    .onSuccess { _state.update { it.copy(toast = "Marked as read") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refreshAll()
        }
    }

    fun createApiKey(comment: String) {
        if (comment.isBlank()) return
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminCreateApiKey(comment)
                    .onSuccess { dto -> _state.update { it.copy(newlyCreatedKey = dto, toast = "API key created") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refreshAll()
        }
    }

    fun deleteApiKey(id: String) {
        viewModelScope.launch {
            withKomgaConnection(connectionId) {
                repository.adminDeleteApiKey(id)
                    .onSuccess { _state.update { it.copy(toast = "API key deleted") } }
                    .onFailure { e -> _state.update { it.copy(error = e.message) } }
            }
            refreshAll()
        }
    }
}
