package com.enve.core.data.sync

sealed interface SyncEvent {
    data class Syncing(val bookId: String) : SyncEvent
    data class Synced(val bookId: String, val percentage: Float, val source: String) : SyncEvent
    data class Failed(val bookId: String, val error: Throwable) : SyncEvent
    data class ConflictDetected(
        val bookId: String,
        val localPercentage: Float,
        val remotePercentage: Float,
        val remoteSource: String,
    ) : SyncEvent
    data class AnnotationsPulled(val bookId: String, val count: Int, val source: String) : SyncEvent
    data class AnnotationsPushed(val bookId: String, val accepted: Int, val rejected: Int) : SyncEvent
    data class AnnotationConflict(
        val bookId: String,
        val annotationId: String,
        val remoteUpdatedAt: Long,
        val localUpdatedAt: Long,
    ) : SyncEvent
}
