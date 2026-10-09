package com.enve.engine.matching

import com.enve.core.data.model.DuplicateBookCluster
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

interface DuplicateMatchingFacade {
    val clusters: Flow<List<DuplicateBookCluster>>
    val grouped: StateFlow<Map<String, String>>
    suspend fun merge(cluster: DuplicateBookCluster, keepBookKey: String): Int
    suspend fun unmerge(keepBookKey: String): Int
}
