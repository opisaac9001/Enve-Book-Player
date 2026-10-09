package com.enve.app.playback

import com.enve.core.data.sync.AudiobookCheckpointOrder
import kotlinx.coroutines.CancellationException

internal class PlaybackCheckpointWriter(
    private val order: AudiobookCheckpointOrder,
    private val write: suspend (PlayerProgressService.Checkpoint) -> PlayerProgressService.PersistedPlaybackProgress?,
) {
    private val lastPersistElapsedMs = mutableMapOf<String, Long>()

    suspend fun persist(checkpoint: PlayerProgressService.Checkpoint, force: Boolean): PlayerProgressService.SaveResult = try {
        order.serialized { state ->
            if (state.isSuperseded(checkpoint.key, checkpoint.sequence)) return@serialized PlayerProgressService.SaveResult.Superseded
            if (!force) {
                if (checkpoint.positionMs <= 0L) return@serialized PlayerProgressService.SaveResult.Retry()
                val previous = lastPersistElapsedMs[checkpoint.key]
                if (previous != null && checkpoint.capturedElapsedMs - previous < 5_000L) {
                    return@serialized PlayerProgressService.SaveResult.Retry()
                }
            }
            val persisted = write(checkpoint) ?: return@serialized PlayerProgressService.SaveResult.Retry()
            state.recordApplied(checkpoint.key, checkpoint.sequence)
            lastPersistElapsedMs[checkpoint.key] = checkpoint.capturedElapsedMs
            PlayerProgressService.SaveResult.Saved(persisted)
        }
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        PlayerProgressService.SaveResult.Retry(error)
    }
}
