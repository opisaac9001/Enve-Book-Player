package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.app.data.sync.BookloreKoreaderSink
import com.enve.app.data.sync.PendingSyncQueue
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class ProviderSyncStatus(
    val connectionId: String,
    val name: String,
    val source: BookSource,
    val serverUrl: String,
    val lastSyncedAt: Long?,
    val isSyncing: Boolean = false,
    val error: String? = null,
)

data class SyncCenterState(
    val providers: List<ProviderSyncStatus> = emptyList(),
    val isSyncingAll: Boolean = false,
    val lastSyncTime: Long = 0L,
    val lastSyncResult: String? = null,
    val pendingCount: Int = 0,
    val autoSyncOnLaunch: Boolean = true,
    val syncOnCellular: Boolean = false,
    val error: String? = null,

    val koreaderUsername: String = "",
    val koreaderPassword: String = "",
    val koreaderEnabled: Boolean = false,
    val koreaderTestResult: String? = null,
    val koreaderTesting: Boolean = false,
)

@HiltViewModel
class SyncCenterViewModel @Inject constructor(
    private val prefs: PreferencesManager,
    private val registry: ConnectionRegistry,
    private val recentlyPlayedSyncService: com.enve.app.data.sync.RecentlyPlayedSyncService,
    private val repository: GrimmoryRepository,
    private val koreaderSink: BookloreKoreaderSink,
    private val pendingQueue: PendingSyncQueue,
) : ViewModel() {

    private val _state = MutableStateFlow(SyncCenterState())
    val state: StateFlow<SyncCenterState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            registry.connections.collect { connections ->
                val statuses = buildProviderStatuses(connections)
                _state.update { it.copy(providers = statuses) }
            }
        }
        viewModelScope.launch {
            prefs.lastSyncTime.collect { lastSync ->
                _state.update { it.copy(lastSyncTime = lastSync, pendingCount = pendingQueue.pendingCount()) }
            }
        }
        viewModelScope.launch {
            prefs.autoSyncOnLaunch.collect { auto ->
                _state.update { it.copy(autoSyncOnLaunch = auto) }
            }
        }
        viewModelScope.launch {
            prefs.syncOnCellular.collect { cellular ->
                _state.update { it.copy(syncOnCellular = cellular) }
            }
        }

        loadKoreaderCredentials()
    }

    private fun buildProviderStatuses(connections: List<ProviderConnection>): List<ProviderSyncStatus> {
        val statuses = connections.filter { it.enabled }.map { conn ->
            ProviderSyncStatus(
                connectionId = conn.id,
                name = conn.name,
                source = conn.source,
                serverUrl = conn.serverUrl,
                lastSyncedAt = conn.lastSyncedAt,
            )
        }.toMutableList()

        if (statuses.isEmpty()) {
            val serverUrl = prefs.getServerUrlSync()
            val username = prefs.getUsernameSync()
            if (!serverUrl.isNullOrBlank()) {
                statuses.add(
                    ProviderSyncStatus(
                        connectionId = "grimmory-legacy",
                        name = "Grimmory${if (!username.isNullOrBlank()) " ($username)" else ""}",
                        source = BookSource.GRIMMORY,
                        serverUrl = serverUrl,
                        lastSyncedAt = null,
                    )
                )
            }
        }
        return statuses
    }

    fun syncNow() {
        viewModelScope.launch {
            _state.update { it.copy(isSyncingAll = true, error = null, lastSyncResult = null) }
            runCatching {
                repository.invalidateListCaches()
                val result = recentlyPlayedSyncService.sync(com.enve.app.data.sync.ServerStatusSyncTrigger.MANUAL_SYNC)
                val summary = "Synced ${result.mergedItemCount} item(s) (${result.pulledItemCount} pulled, ${result.pushedItemCount} pushed)"
                _state.update { it.copy(lastSyncResult = summary, pendingCount = pendingQueue.pendingCount()) }
            }.onFailure { e ->
                _state.update { it.copy(error = e.message ?: "Sync failed") }
            }
            _state.update { it.copy(isSyncingAll = false) }
        }
    }

    fun setAutoSyncOnLaunch(enabled: Boolean) {
        viewModelScope.launch { prefs.setAutoSyncOnLaunch(enabled) }
    }

    fun setSyncOnCellular(enabled: Boolean) {
        viewModelScope.launch { prefs.setSyncOnCellular(enabled) }
    }

    fun loadKoreaderCredentials() {
        val creds = koreaderSink.credentialsForGrimmory()
        _state.update {
            it.copy(
                koreaderUsername = creds?.username ?: "",
                koreaderPassword = creds?.password ?: "",
                koreaderEnabled = creds != null,
            )
        }
    }

    fun setKoreaderUsername(value: String) {
        _state.update { it.copy(koreaderUsername = value, koreaderTestResult = null) }
    }

    fun setKoreaderPassword(value: String) {
        _state.update { it.copy(koreaderPassword = value, koreaderTestResult = null) }
    }

    fun saveKoreaderCredentials() {
        val serverUrl = prefs.getServerUrlSync() ?: return
        val connectionId = prefs.getActiveConnectionIdSync() ?: return
        val username = _state.value.koreaderUsername.trim()
        val password = _state.value.koreaderPassword.trim()
        if (username.isBlank() || password.isBlank()) {
            koreaderSink.clearCredentials(connectionId, serverUrl)
            _state.update { it.copy(koreaderEnabled = false) }
        } else {
            koreaderSink.saveCredentials(connectionId, serverUrl, username, password)
            _state.update { it.copy(koreaderEnabled = true) }
        }
    }

    fun testKoreaderAuth() {
        viewModelScope.launch {
            val serverUrl = prefs.getServerUrlSync() ?: return@launch
            val username = _state.value.koreaderUsername.trim()
            val password = _state.value.koreaderPassword.trim()
            _state.update { it.copy(koreaderTesting = true, koreaderTestResult = null) }
            val result = koreaderSink.testAuth(serverUrl, username, password)
            _state.update {
                it.copy(
                    koreaderTesting = false,
                    koreaderTestResult = if (result.isSuccess) "Connected" else "Failed: ${result.exceptionOrNull()?.message}",
                )
            }
        }
    }

    fun clearKoreaderCredentials() {
        val serverUrl = prefs.getServerUrlSync() ?: return
        val connectionId = prefs.getActiveConnectionIdSync() ?: return
        koreaderSink.clearCredentials(connectionId, serverUrl)
        _state.update { it.copy(koreaderUsername = "", koreaderPassword = "", koreaderEnabled = false, koreaderTestResult = null) }
    }
}
