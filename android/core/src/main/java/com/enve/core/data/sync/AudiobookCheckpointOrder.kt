package com.enve.core.data.sync

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

@Singleton
class AudiobookCheckpointOrder @Inject constructor() {
    private val sequence = AtomicLong()
    private val gate = Mutex()
    private val latestCaptures = ConcurrentHashMap<String, Long>()
    private val applied = mutableMapOf<String, Long>()
    private val state = State(applied, latestCaptures)

    fun newSequence(): Long = sequence.incrementAndGet()

    fun capture(key: String): Long = newSequence().also { token ->
        latestCaptures.merge(key, token, ::maxOf)
    }

    suspend fun <T> serialized(action: suspend (State) -> T): T =
        withContext(Dispatchers.IO) { gate.withLock { action(state) } }

    class State internal constructor(
        private val applied: MutableMap<String, Long>,
        private val captures: Map<String, Long>,
    ) {
        fun isSuperseded(key: String, token: Long): Boolean = token <= (applied[key] ?: 0L)
        fun changedSince(key: String, token: Long): Boolean = (applied[key] ?: 0L) > token
        fun hasCaptureAfter(key: String, token: Long): Boolean = (captures[key] ?: 0L) > token
        fun hasPendingCapture(key: String): Boolean = (captures[key] ?: 0L) > (applied[key] ?: 0L)
        fun recordApplied(key: String, token: Long) {
            applied[key] = maxOf(applied[key] ?: 0L, token)
        }
    }
}
