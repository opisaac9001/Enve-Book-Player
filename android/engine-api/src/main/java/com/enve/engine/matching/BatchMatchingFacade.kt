package com.enve.engine.matching

import kotlinx.coroutines.flow.StateFlow

data class PendingMetadataMatch(
    val bookKey: String,
    val title: String,
    val candidateId: String,
    val sourceName: String,
    val confidence: Double,
)

interface BatchMatchingFacade {
    val pending: StateFlow<List<PendingMetadataMatch>>
    val threshold: StateFlow<Int>
    suspend fun setThreshold(percent: Int)
    suspend fun queue(entry: PendingMetadataMatch)
    suspend fun remove(bookKey: String)
    suspend fun clear()
}
