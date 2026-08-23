package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import com.enve.silo.SiloRepository
import com.enve.silo.dto.SiloAdminServerStatusDto
import com.enve.silo.dto.SiloAdminStatsDto
import com.enve.silo.dto.SiloAdminUserDto
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class SiloAdminState(
    val connections: List<ProviderConnection> = emptyList(),
    val selectedConnectionId: String? = null,
    val stats: SiloAdminStatsDto? = null,
    val serverStatus: SiloAdminServerStatusDto? = null,
    val users: List<SiloAdminUserDto> = emptyList(),
    val isLoading: Boolean = false,
    val message: String? = null,
) {
    val adminConnections: List<ProviderConnection>
        get() = connections.filter { it.source == BookSource.SILO && it.enabled && it.isAdmin }

    val selectedConnection: ProviderConnection?
        get() = adminConnections.firstOrNull { it.id == selectedConnectionId } ?: adminConnections.firstOrNull()
}

@HiltViewModel
class SiloAdminViewModel @Inject constructor(
    connectionRegistry: ConnectionRegistry,
    private val siloRepository: SiloRepository,
) : ViewModel() {
    private val localState = MutableStateFlow(SiloAdminState())

    val state: StateFlow<SiloAdminState> = combine(
        connectionRegistry.connections,
        localState,
    ) { connections, local ->
        val adminConnections = connections.filter { it.source == BookSource.SILO && it.enabled && it.isAdmin }
        val selected = local.selectedConnectionId?.takeIf { id -> adminConnections.any { it.id == id } }
            ?: adminConnections.firstOrNull()?.id
        local.copy(connections = connections, selectedConnectionId = selected)
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = SiloAdminState(),
    )

    init {
        viewModelScope.launch {
            state.collect { current ->
                if (current.stats == null && !current.isLoading && current.selectedConnection != null) {
                    refresh()
                }
            }
        }
    }

    fun selectConnection(connectionId: String) {
        localState.update {
            it.copy(
                selectedConnectionId = connectionId,
                stats = null,
                serverStatus = null,
                users = emptyList(),
                message = null,
            )
        }
        refresh()
    }

    fun refresh() {
        val connection = state.value.selectedConnection ?: return
        viewModelScope.launch {
            localState.update { it.copy(isLoading = true, message = null) }
            val result = withContext(ConnectionScope.asContextElement(connection.id)) {
                runCatching {
                    Triple(
                        siloRepository.getAdminStats().getOrThrow(),
                        siloRepository.getAdminServerStatus().getOrThrow(),
                        siloRepository.getAdminUsers().getOrThrow(),
                    )
                }
            }
            result.onSuccess { (stats, status, users) ->
                localState.update {
                    it.copy(
                        stats = stats,
                        serverStatus = status,
                        users = users,
                        isLoading = false,
                        message = "Updated ${connection.name}",
                    )
                }
            }.onFailure { error ->
                localState.update {
                    it.copy(
                        isLoading = false,
                        message = error.message ?: "Silo admin refresh failed",
                    )
                }
            }
        }
    }

    fun clearMessage() {
        localState.update { it.copy(message = null) }
    }
}
