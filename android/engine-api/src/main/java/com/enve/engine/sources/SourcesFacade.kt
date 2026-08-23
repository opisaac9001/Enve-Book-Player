package com.enve.engine.sources

import com.enve.core.data.model.ProviderConnection
import kotlinx.coroutines.flow.Flow

interface SourcesFacade {
    val connections: Flow<List<ProviderConnection>>
    suspend fun update(connection: ProviderConnection)
    suspend fun setEnabled(id: String, enabled: Boolean)
    suspend fun remove(id: String)
}
