package com.enve.core.data.local

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ConnectionRegistry @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val dataStore get() = context.enveDataStore

    private val json = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        encodeDefaults = true
    }

    private object Keys {
        val CONNECTIONS_JSON = stringPreferencesKey("enve.connections.json")
    }

    val connections: Flow<List<ProviderConnection>> = dataStore.data.map { prefs ->
        decodeConnections(prefs[Keys.CONNECTIONS_JSON])
    }

    fun getConnectionsSync(): List<ProviderConnection> {
        val raw = runBlocking { dataStore.data.first()[Keys.CONNECTIONS_JSON] }
        return decodeConnections(raw)
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
        }
    }

    suspend fun remove(connectionId: String) {
        dataStore.edit { prefs ->
            val existing = decodeConnections(prefs[Keys.CONNECTIONS_JSON])
            val updated = existing.filterNot { it.id == connectionId }
            prefs[Keys.CONNECTIONS_JSON] = encodeConnections(updated)
        }
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

    private fun decodeConnections(raw: String?): List<ProviderConnection> {
        if (raw.isNullOrBlank()) return emptyList()
        return runCatching {
            json.decodeFromString(ListSerializer(ProviderConnection.serializer()), raw)
        }.getOrDefault(emptyList())
    }

    private fun encodeConnections(connections: List<ProviderConnection>): String {
        return json.encodeToString(ListSerializer(ProviderConnection.serializer()), connections)
    }
}
