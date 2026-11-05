package com.enve.app.hearth

import com.enve.app.auth.MtlsManager
import com.enve.app.data.repository.AggregatorRepository
import com.enve.app.data.repository.LibraryCacheRepository
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.ProviderConnection
import com.enve.engine.sources.SourcesFacade
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SourcesFacadeImpl @Inject constructor(
    private val registry: ConnectionRegistry,
    private val vault: CredentialVault,
    private val cache: LibraryCacheRepository,
    private val aggregator: AggregatorRepository,
    private val prefs: PreferencesManager,
    private val mtlsManager: MtlsManager,
) : SourcesFacade {
    override val connections: Flow<List<ProviderConnection>> = registry.connections

    override suspend fun update(connection: ProviderConnection) {
        val normalized = connection.copy(serverUrl = connection.serverUrl.trim().trimEnd('/'))
        val previous = registry.connections.first().firstOrNull { it.id == normalized.id }
        registry.upsert(normalized)
        if (previous != null && previous.serverUrl.trim().trimEnd('/') != normalized.serverUrl && normalized.enabled) {
            cache.invalidateAndRefresh(listOf(normalized.id))
        }
    }

    override suspend fun setEnabled(id: String, enabled: Boolean) {
        registry.setEnabled(id, enabled)
        aggregator.clearHomeSnapshotCache()
        if (enabled) cache.ingestConnectionsInBackground(listOf(id))
    }

    override suspend fun remove(id: String) {
        vault.remove(CredentialVault.accessTokenKey(id))
        vault.remove(CredentialVault.refreshTokenKey(id))
        vault.remove(CredentialVault.passwordKey(id))
        vault.remove(CredentialVault.usernameKey(id))
        vault.remove(CredentialVault.serviceClientIdKey(id))
        vault.remove(CredentialVault.serviceClientSecretKey(id))
        vault.remove(CredentialVault.kosyncUsernameKeyForConnection(id))
        vault.remove(CredentialVault.kosyncPasswordKeyForConnection(id))
        mtlsManager.clearCert(id)
        cache.clearForConnection(id)
        aggregator.invalidateCaches()
        aggregator.clearHomeSnapshotCache()
        registry.remove(id)
        if (prefs.activeConnectionId.first() == id) prefs.clearActiveConnectionId()
        if (registry.connections.first().isEmpty()) prefs.clearAuth()
    }
}
