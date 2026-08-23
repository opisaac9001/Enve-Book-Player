package com.enve.app.data.repository

import com.enve.app.data.repository.GrimmoryAppRepository
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.model.toLegacyLibrary
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.util.runSuspendCatching
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class LibraryListResolver @Inject constructor(
    private val connectionRegistry: ConnectionRegistry,
    private val grimmoryApp: GrimmoryAppRepository,
    private val opds: OpdsRepository,
    private val aggregator: AggregatorRepository,
) {
    suspend fun resolveAll(): List<Library> {
        val conns = connectionRegistry.connections.first().filter { it.enabled }
        if (conns.isEmpty()) return emptyList()
        val merged = mutableListOf<Library>()
        for (conn in conns) {
            when (conn.source) {
                BookSource.GRIMMORY -> {
                    grimmoryApp.getLibraries(conn.id).onSuccess { libs ->
                        merged += libs.map { it.toLegacyLibrary(conn.id) }
                    }
                }
                BookSource.OPDS -> {
                    opds.getLibraries(conn.id).onSuccess { merged += it }
                }

                else -> {
                    runSuspendCatching {
                        withContext(ConnectionScope.asContextElement(conn.id)) {
                            aggregator.getLibraries()
                        }
                    }.getOrNull()?.getOrNull()
                        ?.filter { it.connectionId == conn.id }
                        ?.let { merged += it }
                }
            }
        }
        return merged.distinctBy { it.id }
    }
}
