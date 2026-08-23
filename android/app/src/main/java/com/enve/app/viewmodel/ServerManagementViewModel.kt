package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.auth.MtlsManager
import com.enve.app.data.repository.AggregatorRepository
import com.enve.app.data.repository.LibraryCacheRepository
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.engine.servertools.ServerFeature
import com.enve.engine.servertools.ServerToolsFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ServerManagementState(
    val connections: List<ProviderConnection> = emptyList(),
    val connectionHealth: Map<String, Boolean> = emptyMap(),
    val connectionFeatures: Map<String, Set<ServerFeature>> = emptyMap(),
    val isCheckingHealth: Boolean = false,
    val busyConnectionIds: Set<String> = emptySet(),
    val message: String? = null,
) {
    val activeConnections: List<ProviderConnection>
        get() = connections.filter { it.enabled }

    val pausedConnections: List<ProviderConnection>
        get() = connections.filterNot { it.enabled }

    val platformCount: Int
        get() = activeConnections.map { it.source }.distinct().size

    fun forSource(source: BookSource): List<ProviderConnection> =
        connections.filter { it.source == source }
}

@HiltViewModel
class ServerManagementViewModel @Inject constructor(
    private val connectionRegistry: ConnectionRegistry,
    private val libraryCacheRepository: LibraryCacheRepository,
    private val aggregatorRepository: AggregatorRepository,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
    private val mtlsManager: MtlsManager,
    serverTools: ServerToolsFacade,
) : ViewModel() {
    private val localState = MutableStateFlow(ServerManagementState())

    val state: StateFlow<ServerManagementState> = combine(
        connectionRegistry.connections,
        serverTools.targets,
        localState,
    ) { connections, targets, local ->
        local.copy(
            connections = connections,
            connectionFeatures = targets.associate { it.connectionId to it.features },
        )
    }
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5_000),
            initialValue = ServerManagementState(),
        )

    fun refreshHealth() {
        if (localState.value.isCheckingHealth) return
        viewModelScope.launch {
            localState.update { it.copy(isCheckingHealth = true, message = null) }
            val result = runCatching { aggregatorRepository.checkAllConnectionsHealth() }
                .getOrElse { emptyMap() }
            localState.update {
                it.copy(
                    connectionHealth = result,
                    isCheckingHealth = false,
                    message = "Checked ${result.size} enabled connection(s)",
                )
            }
        }
    }

    fun refreshConnection(connectionId: String) {
        val connection = state.value.connections.find { it.id == connectionId } ?: return
        if (!connection.enabled) {
            localState.update { it.copy(message = "Resume ${connection.name} before refreshing it") }
            return
        }
        viewModelScope.launch {
            setBusy(connectionId, true)
            runCatching {
                libraryCacheRepository.clearForConnection(connectionId)
                aggregatorRepository.invalidateCaches()
                aggregatorRepository.clearHomeSnapshotCache()
                libraryCacheRepository.ingestConnectionsInBackground(listOf(connectionId))
            }
            setBusy(connectionId, false)
            localState.update { it.copy(message = "Refreshing ${connection.name}") }
        }
    }

    fun setConnectionEnabled(connectionId: String, enabled: Boolean) {
        val connection = state.value.connections.find { it.id == connectionId } ?: return
        viewModelScope.launch {
            setBusy(connectionId, true)
            connectionRegistry.setEnabled(connectionId, enabled)
            if (enabled) {
                libraryCacheRepository.ingestConnectionsInBackground(listOf(connectionId))
            } else {
                runCatching { libraryCacheRepository.clearForConnection(connectionId) }
                runCatching { aggregatorRepository.invalidateCaches() }
                runCatching { aggregatorRepository.clearHomeSnapshotCache() }
            }
            setBusy(connectionId, false)
            localState.update {
                it.copy(message = if (enabled) "Resumed ${connection.name}" else "Paused ${connection.name}")
            }
        }
    }

    fun removeConnection(connectionId: String) {
        val connection = state.value.connections.find { it.id == connectionId } ?: return
        viewModelScope.launch {
            setBusy(connectionId, true)
            vault.remove(CredentialVault.accessTokenKey(connectionId))
            vault.remove(CredentialVault.refreshTokenKey(connectionId))
            vault.remove(CredentialVault.passwordKey(connectionId))
            vault.remove(CredentialVault.usernameKey(connectionId))
            vault.remove(CredentialVault.serviceClientIdKey(connectionId))
            vault.remove(CredentialVault.serviceClientSecretKey(connectionId))
            vault.remove(CredentialVault.kosyncUsernameKeyForConnection(connectionId))
            vault.remove(CredentialVault.kosyncPasswordKeyForConnection(connectionId))
            mtlsManager.clearCert(connectionId)

            runCatching { libraryCacheRepository.clearForConnection(connectionId) }
            runCatching { aggregatorRepository.invalidateCaches() }
            runCatching { aggregatorRepository.clearHomeSnapshotCache() }
            connectionRegistry.remove(connectionId)

            if (prefs.activeConnectionId.first() == connectionId) {
                prefs.clearActiveConnectionId()
            }
            if (connectionRegistry.connections.first().isEmpty()) {
                prefs.clearAuth()
            }
            setBusy(connectionId, false)
            localState.update { it.copy(message = "Removed ${connection.name}") }
        }
    }

    fun clearMessage() {
        localState.update { it.copy(message = null) }
    }

    private fun setBusy(connectionId: String, busy: Boolean) {
        localState.update { state ->
            val busyIds = if (busy) {
                state.busyConnectionIds + connectionId
            } else {
                state.busyConnectionIds - connectionId
            }
            state.copy(busyConnectionIds = busyIds)
        }
    }
}
