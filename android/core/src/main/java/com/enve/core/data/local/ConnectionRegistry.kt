package com.enve.core.data.local

import com.enve.core.auth.CredentialVault
import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ConnectionRegistry(
    private val dataStore: DataStore<Preferences>,
    private val vault: CredentialVault,
) {
    @Inject
    constructor(@ApplicationContext context: Context, vault: CredentialVault) : this(context.enveDataStore, vault)

    private val json = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        encodeDefaults = true
    }

    private object Keys {
        val CONNECTIONS_JSON = stringPreferencesKey("enve.connections.json")
        val REVISION = stringPreferencesKey("enve.connections.revision")
    }

    val connections: Flow<List<ProviderConnection>> = flow {
        migrateCredentials()
        emitAll(dataStore.data.map { prefs -> decodeConnections(prefs[Keys.CONNECTIONS_JSON]) })
    }

    fun getConnectionsSync(): List<ProviderConnection> = runBlocking {
        decodeConnections(dataStore.data.first()[Keys.CONNECTIONS_JSON])
    }

    private suspend fun migrateCredentials() {
        dataStore.edit { prefs ->
            val raw = decodeStoredConnections(prefs[Keys.CONNECTIONS_JSON])
            if (raw.any { it.customHeaders.isNotEmpty() || it.serviceClientId.isNotEmpty() || it.serviceClientSecret.isNotEmpty() }) {
                prefs[Keys.CONNECTIONS_JSON] = encodeConnections(raw.map(::restoreCredentials))
            }
        }
    }

    fun getScopedConnectionSync(): ProviderConnection? {
        val connectionId = ConnectionScope.getConnectionId() ?: return null
        return getConnectionsSync().find { it.id == connectionId }
    }

    suspend fun upsert(connection: ProviderConnection) {
        dataStore.edit { prefs ->
            val existing = decodeConnections(prefs[Keys.CONNECTIONS_JSON])
            val updated = existing
                .filterNot { it.id == connection.id }
                .plus(connection)
                .sortedByDescending { it.createdAt }
            prefs[Keys.CONNECTIONS_JSON] = encodeConnections(updated)
            prefs[Keys.REVISION] = java.util.UUID.randomUUID().toString()
        }
    }

    suspend fun remove(connectionId: String) {
        dataStore.edit { prefs ->
            val existing = decodeConnections(prefs[Keys.CONNECTIONS_JSON])
            val updated = existing.filterNot { it.id == connectionId }
            prefs[Keys.CONNECTIONS_JSON] = encodeConnections(updated)
        }
        vault.remove(CredentialVault.customHeadersKey(connectionId))
        vault.remove(CredentialVault.serviceClientIdKey(connectionId))
        vault.remove(CredentialVault.serviceClientSecretKey(connectionId))
    }

    suspend fun setEnabled(connectionId: String, enabled: Boolean) {
        dataStore.edit { prefs ->
            val existing = decodeConnections(prefs[Keys.CONNECTIONS_JSON])
            val updated = existing.map {
                if (it.id == connectionId) it.copy(enabled = enabled) else it
            }
            prefs[Keys.CONNECTIONS_JSON] = encodeConnections(updated)
        }
    }

    suspend fun setLastSynced(connectionId: String, timestamp: Long) {
        dataStore.edit { prefs ->
            val existing = decodeConnections(prefs[Keys.CONNECTIONS_JSON])
            val updated = existing.map {
                if (it.id == connectionId) it.copy(lastSyncedAt = timestamp) else it
            }
            prefs[Keys.CONNECTIONS_JSON] = encodeConnections(updated)
        }
    }

    private fun decodeStoredConnections(raw: String?): List<ProviderConnection> {
        if (raw.isNullOrBlank()) return emptyList()
        return json.decodeFromString(ListSerializer(ProviderConnection.serializer()), raw)
    }

    private fun decodeConnections(raw: String?): List<ProviderConnection> =
        decodeStoredConnections(raw).map(::restoreCredentials)

    private fun restoreCredentials(connection: ProviderConnection): ProviderConnection = connection.copy(
        customHeaders = connection.customHeaders.ifEmpty {
            vault.get(CredentialVault.customHeadersKey(connection.id))?.let {
                json.decodeFromString(MapSerializer(String.serializer(), String.serializer()), it)
            }.orEmpty()
        },
        serviceClientId = connection.serviceClientId.ifEmpty {
            vault.get(CredentialVault.serviceClientIdKey(connection.id)).orEmpty()
        },
        serviceClientSecret = connection.serviceClientSecret.ifEmpty {
            vault.get(CredentialVault.serviceClientSecretKey(connection.id)).orEmpty()
        },
    )

    private fun persistCredential(key: String, value: String) {
        if (vault.get(key) != value) vault.put(key, value)
    }

    private fun encodeConnections(connections: List<ProviderConnection>): String {
        val stored = connections.map { connection ->
            persistCredential(CredentialVault.customHeadersKey(connection.id),
                json.encodeToString(MapSerializer(String.serializer(), String.serializer()), connection.customHeaders))
            persistCredential(CredentialVault.serviceClientIdKey(connection.id), connection.serviceClientId)
            persistCredential(CredentialVault.serviceClientSecretKey(connection.id), connection.serviceClientSecret)
            connection.copy(customHeaders = emptyMap(), serviceClientId = "", serviceClientSecret = "")
        }
        return json.encodeToString(ListSerializer(ProviderConnection.serializer()), stored)
    }
}
