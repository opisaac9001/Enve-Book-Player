package com.enve.app.readium

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class ReadAloudCheckpointSequencer<T>(
    private val writer: suspend (T) -> Unit,
) {
    private data class Pending<T>(
        val sequence: Long,
        val value: T,
    )

    private data class BookState<T>(
        var activeToken: ReadAloudCheckpointToken,
        var latestRevision: Long = -1L,
        var nextSequence: Long = 0L,
        var pending: Pending<T>? = null,
        var persistedSequence: Long = -1L,
    )

    private val stateLock = Any()
    private val writeMutex = Mutex()
    private val states = mutableMapOf<String, BookState<T>>()

    fun beginSession(token: ReadAloudCheckpointToken) {
        synchronized(stateLock) {
            val existing = states[token.bookKey]
            if (existing == null) {
                states[token.bookKey] = BookState(activeToken = token)
            } else {
                existing.activeToken = token
                existing.latestRevision = -1L
            }
        }
    }

    fun offer(token: ReadAloudCheckpointToken, revision: Long, value: T): Boolean =
        synchronized(stateLock) {
            val state = states[token.bookKey]
                ?: return@synchronized false
            if (token != state.activeToken || revision <= state.latestRevision) {
                return@synchronized false
            }
            state.latestRevision = revision
            state.nextSequence += 1L
            state.pending = Pending(state.nextSequence, value)
            true
        }

    fun pendingBookKeys(): List<String> = synchronized(stateLock) {
        states.mapNotNull { (bookKey, state) ->
            bookKey.takeIf { state.pending?.sequence?.let { it > state.persistedSequence } == true }
        }
    }

    suspend fun flush(bookKey: String) {
        writeMutex.withLock {
            while (true) {
                val pending = synchronized(stateLock) {
                    states[bookKey]?.let { state ->
                        state.pending?.takeIf { it.sequence > state.persistedSequence }
                    }
                } ?: return@withLock

                writer(pending.value)

                synchronized(stateLock) {
                    states[bookKey]?.let { state ->
                        if (pending.sequence > state.persistedSequence) {
                            state.persistedSequence = pending.sequence
                        }
                    }
                }
            }
        }
    }
}
