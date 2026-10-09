package com.enve.app.playback

internal class PlaybackCheckpointBuffer {
    private val lock = Any()
    private val pending = mutableMapOf<String, PlayerProgressService.Checkpoint>()
    private var latest: PlayerProgressService.Checkpoint? = null

    fun retain(snapshot: PlayerProgressService.Checkpoint): PlayerProgressService.Checkpoint = synchronized(lock) {
        if (snapshot.sequence > (pending[snapshot.key]?.sequence ?: 0L)) pending[snapshot.key] = snapshot
        if (snapshot.sequence > (latest?.sequence ?: 0L)) latest = snapshot
        snapshot
    }

    fun acknowledge(snapshot: PlayerProgressService.Checkpoint, result: PlayerProgressService.SaveResult) = synchronized(lock) {
        if (result !is PlayerProgressService.SaveResult.Retry && pending[snapshot.key] == snapshot) pending.remove(snapshot.key)
        Unit
    }

    fun latestSnapshot(): PlayerProgressService.Checkpoint? = synchronized(lock) { latest }

    fun pendingSnapshots(): List<PlayerProgressService.Checkpoint> = synchronized(lock) { pending.values.sortedBy { it.sequence } }

    suspend fun persistCaptured(
        snapshot: PlayerProgressService.Checkpoint,
        beforePersist: suspend () -> Unit = {},
        write: suspend (PlayerProgressService.Checkpoint) -> PlayerProgressService.SaveResult,
    ): PlayerProgressService.SaveResult {
        retain(snapshot)
        beforePersist()
        return write(snapshot).also { acknowledge(snapshot, it) }
    }

    suspend fun flush(write: suspend (PlayerProgressService.Checkpoint) -> PlayerProgressService.SaveResult) {
        for (snapshot in pendingSnapshots()) persistCaptured(snapshot, write = write)
    }
}
