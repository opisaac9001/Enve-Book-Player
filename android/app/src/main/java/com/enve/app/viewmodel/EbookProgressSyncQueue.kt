package com.enve.app.viewmodel

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class EbookProgressSyncQueue(
    private val scope: CoroutineScope,
    private val nowMs: () -> Long,
) {
    private val mutex = Mutex()
    private var timer: Job? = null
    private var pending: (suspend () -> Result<Unit>)? = null
    private var lastAttemptMs: Long? = null
    @Volatile private var readerActive = true

    fun setReaderActive(active: Boolean) {
        readerActive = active
    }

    suspend fun discard() = mutex.withLock {
        timer?.cancel()
        timer = null
        pending = null
    }

    suspend fun submit(intervalMs: Long, push: suspend () -> Result<Unit>): Result<Unit> = mutex.withLock {
        pending = push
        if (intervalMs == 0L || !readerActive) {
            timer?.cancel()
            return@withLock drain()
        }
        if (timer == null) {
            val now = nowMs()
            val wait = ((lastAttemptMs ?: now) + intervalMs - now).coerceAtLeast(0L)
            timer = scope.launch {
                delay(wait)
                mutex.withLock { drain() }
            }
        }
        Result.success(Unit)
    }

    suspend fun flush(): Result<Unit> = mutex.withLock {
        timer?.cancel()
        drain()
    }

    private suspend fun drain(): Result<Unit> {
        timer = null
        val push = pending ?: return Result.success(Unit)
        pending = null
        lastAttemptMs = nowMs()
        val result = try {
            push()
        } catch (e: CancellationException) {
            pending = push
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
        if (result.isFailure) pending = push
        return result
    }
}
