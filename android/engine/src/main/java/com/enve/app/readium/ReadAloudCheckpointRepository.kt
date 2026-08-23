package com.enve.app.readium

import android.util.Log
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.model.BookSource
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

data class ReadAloudCheckpointToken(
    val bookKey: String,
    val sessionId: String,
)

data class ReadAloudCheckpoint(
    val bookId: String,
    val connectionId: String?,
    val progress: Float,
    val currentTimeSec: Long,
    val locatorJson: String,
    val updatedAtMs: Long,
)

object ReadAloudBookKey {
    fun create(bookId: String, source: BookSource, connectionId: String?): String =
        "${connectionId ?: source.name}:$bookId"
}

@Singleton
class ReadAloudCheckpointRepository @Inject constructor(
    private val bookCache: BookCacheDao,
) {
    companion object {
        private const val TAG = "ReadAloudCheckpoint"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val sequencer = ReadAloudCheckpointSequencer<ReadAloudCheckpoint> { checkpoint ->
        bookCache.updateUnifiedProgress(
            bookId = checkpoint.bookId,
            connectionId = checkpoint.connectionId,
            progress = checkpoint.progress,
            currentTimeSec = checkpoint.currentTimeSec,
            locatorJson = checkpoint.locatorJson,
            nowMs = checkpoint.updatedAtMs,
        )
    }

    fun beginSession(bookId: String, source: BookSource, connectionId: String?): ReadAloudCheckpointToken {
        val token = ReadAloudCheckpointToken(
            bookKey = ReadAloudBookKey.create(bookId, source, connectionId),
            sessionId = UUID.randomUUID().toString(),
        )
        sequencer.beginSession(token)
        return token
    }

    fun submit(token: ReadAloudCheckpointToken, revision: Long, checkpoint: ReadAloudCheckpoint) {
        if (!sequencer.offer(token, revision, checkpoint)) return
        scope.launch {
            runCatching { sequencer.flush(token.bookKey) }
                .onFailure { Log.w(TAG, "Could not persist read-aloud checkpoint", it) }
        }
    }

    suspend fun flush(bookId: String, source: BookSource, connectionId: String?) {
        val bookKey = ReadAloudBookKey.create(bookId, source, connectionId)
        runCatching { sequencer.flush(bookKey) }
            .onFailure { Log.w(TAG, "Could not flush read-aloud checkpoint", it) }
    }

    suspend fun flushPending() {
        sequencer.pendingBookKeys().forEach { bookKey ->
            runCatching { sequencer.flush(bookKey) }
                .onFailure { Log.w(TAG, "Could not flush read-aloud checkpoint", it) }
        }
    }
}
