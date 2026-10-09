package com.enve.app.data.offline

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.util.concurrent.atomic.AtomicReference

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
