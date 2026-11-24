package com.enve.app.data.offline

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.util.concurrent.atomic.AtomicReference

private val byteRange = Regex("""bytes (\d+)-(\d+)/(\d+)""", RegexOption.IGNORE_CASE)

internal fun completeBookRangeLength(
    header: String?,
    offset: Long,
    contentLength: Long,
    storedValidator: String?,
    responseValidator: String?,
): Long {
    val parts = header?.let(byteRange::matchEntire)?.groupValues ?: error("Invalid book byte range")
    val total = parts[3].toLongOrNull() ?: error("Invalid book length")
    check(total > offset && parts[1].toLongOrNull() == offset && parts[2].toLongOrNull() == total - 1 &&
        (contentLength < 0 || contentLength == total - offset)) { "Incomplete or shifted book byte range" }
    check(offset == 0L || (storedValidator != null && (responseValidator == null || responseValidator == storedValidator))) {
        "Book changed while resuming"
    }
    return total
}

internal class DownloadTransferLocks {
    private class Entry(val mutex: Mutex = Mutex(), var users: Int = 0)
    private val locks = mutableMapOf<String, Entry>()

    suspend fun <T> withKey(key: String, block: suspend () -> T): T {
        val entry = synchronized(locks) { locks.getOrPut(key) { Entry() }.also { it.users++ } }
        try {
            return entry.mutex.withLock { block() }
        } finally {
            synchronized(locks) {
                if (--entry.users == 0) locks.remove(key)
            }
        }
    }
}

internal class DownloadCalls(private val client: OkHttpClient) {
    private val active = AtomicReference<Call?>()

    suspend fun execute(request: Request): Response {
        currentCoroutineContext().ensureActive()
        val call = client.newCall(request)
        active.set(call)
        currentCoroutineContext().ensureActive()
        return call.execute()
    }

    fun cancel() {
        active.getAndSet(null)?.cancel()
    }
}

internal suspend fun <T> OkHttpClient.withDownloadCalls(block: suspend (DownloadCalls) -> T): T = coroutineScope {
    val calls = DownloadCalls(this@withDownloadCalls)
    val cancellation = launch(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) {
        try {
            awaitCancellation()
        } finally {
            calls.cancel()
        }
    }
    try {
        block(calls)
    } finally {
        cancellation.cancelAndJoin()
    }
}
