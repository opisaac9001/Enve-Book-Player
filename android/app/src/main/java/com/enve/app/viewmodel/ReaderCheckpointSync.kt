package com.enve.app.viewmodel

import com.enve.core.reader.EpubBridgeCheckpoint
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

internal data class CheckpointCandidate(
    val checkpoint: EpubBridgeCheckpoint,
    val observedAt: Long,
    val local: Boolean = false,
)

private fun checkpointPrecision(checkpoint: EpubBridgeCheckpoint): Int = when {
    !checkpoint.epubCfi.isNullOrBlank() -> 4
    !checkpoint.textQuote?.exact.isNullOrBlank() -> 3
    checkpoint.domRange != null || !checkpoint.cssSelector.isNullOrBlank() -> 2
    !checkpoint.href.isNullOrBlank() -> 1
    else -> 0
}

internal fun selectCheckpointCandidate(candidates: List<CheckpointCandidate>): EpubBridgeCheckpoint? {
    val newest = candidates.maxWithOrNull(
        compareBy<CheckpointCandidate> { it.observedAt }
            .thenBy { checkpointPrecision(it.checkpoint) },
    ) ?: return null
    val local = candidates.firstOrNull(CheckpointCandidate::local) ?: return newest.checkpoint
    if (newest === local || local.checkpoint.revision <= 0L) return newest.checkpoint
    val sameFoliateCfi = local.checkpoint.epubCfi != null &&
        local.checkpoint.epubCfi == newest.checkpoint.epubCfi
    return if (sameFoliateCfi) {
        local.checkpoint.copy(observedAt = newest.observedAt)
    } else {
        newest.checkpoint
    }
}

internal class FoliateCheckpointSync {
    private val mutex = Mutex()
    private var pending: EpubBridgeCheckpoint? = null

    val hasPending: Boolean get() = pending != null

    fun submit(checkpoint: EpubBridgeCheckpoint) {
        pending = checkpoint
    }

    fun reset() {
        pending = null
    }

    suspend fun flush(
        commit: suspend (EpubBridgeCheckpoint) -> EpubBridgeCheckpoint?,
        onCommitted: (EpubBridgeCheckpoint, EpubBridgeCheckpoint) -> Unit,
        push: suspend (EpubBridgeCheckpoint) -> Result<Unit>,
    ) = withContext(NonCancellable) {
        mutex.withLock {
            withTimeoutOrNull(15_000L) {
                val checkpoint = pending ?: return@withTimeoutOrNull
                val committed = commit(checkpoint) ?: return@withTimeoutOrNull
                pending = if (pending === checkpoint) committed
                else pending?.copy(revision = committed.revision)
                onCommitted(checkpoint, committed)
                val result = push(committed)
                (result.exceptionOrNull() as? CancellationException)?.let { throw it }
                if (result.isSuccess && pending === committed) pending = null
            }
        }
    }
}
