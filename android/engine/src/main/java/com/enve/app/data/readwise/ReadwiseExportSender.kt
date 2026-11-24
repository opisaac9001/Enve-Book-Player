package com.enve.app.data.readwise

import com.enve.engine.readwise.ReadwiseExportProgress
import com.enve.engine.readwise.ReadwiseExportResult
import com.enve.engine.readwise.ReadwiseFailure
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.IOException

internal class ReadwiseExportSender(
    private val client: ReadwiseClient,
    private val receipts: ReadwiseReceiptStore,
    private val pause: suspend (Long) -> Unit = { delay(it) },
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private var lastRequestAt: Long? = null
    private var lastListRequestAt: Long? = null

    suspend fun send(
        token: String,
        account: String,
        pending: List<ReadwisePendingHighlight>,
        onProgress: (ReadwiseExportProgress) -> Unit,
    ): ReadwiseExportResult {
        var sent = 0
        onProgress(ReadwiseExportProgress(sent, pending.size))
        for (highlight in pending) {
            val remoteId = try {
                deliver(token, highlight)
            } catch (e: ReadwiseRequestException) {
                return ReadwiseExportResult(sent, pending.size - sent, e.failure, e.retryAfterSeconds)
            }
            try {
                withContext(NonCancellable) {
                    receipts.record(account, mapOf(highlight.annotationId to ReadwiseReceipt(remoteId, highlight.fingerprint)))
                }
            } catch (_: IOException) {
                return ReadwiseExportResult(sent, pending.size - sent, ReadwiseFailure.STORAGE)
            }
            sent++
            onProgress(ReadwiseExportProgress(sent, pending.size))
            currentCoroutineContext().ensureActive()
        }
        return ReadwiseExportResult(sent, 0, null)
    }

    private suspend fun deliver(token: String, highlight: ReadwisePendingHighlight): Long {
        highlight.remoteId?.let { remoteId ->
            if (request { client.updateHighlight(token, remoteId, highlight.payload.update()) }) return remoteId
        }
        val books = request { client.createHighlight(token, highlight.payload) }
        books.flatMap { it.modifiedHighlights }.distinct().singleOrNull()?.let { return it }
        val book = books.singleOrNull() ?: throw readwiseUnconfirmed()
        val recoveredId = lookUp(token, book.id, highlight.payload.text)
        if (!request { client.updateHighlight(token, recoveredId, highlight.payload.update()) }) throw readwiseUnconfirmed()
        return recoveredId
    }

    private suspend fun lookUp(token: String, bookId: Long, text: String): Long {
        for (page in 1..MAX_LOOKUP_PAGES) {
            val result = request(list = true) { client.highlightsPage(token, bookId, page) }
            val matches = result.results.filter { it.text.trim() == text }
            if (matches.size > 1) throw readwiseUnconfirmed()
            matches.singleOrNull()?.let { return it.id }
            if (result.next == null) break
        }
        throw readwiseUnconfirmed()
    }

    private suspend fun <T> request(list: Boolean = false, call: suspend () -> T): T {
        var attempt = 1
        while (true) {
            val error = try {
                awaitSlot(list)
                return call()
            } catch (e: ReadwiseRequestException) {
                e
            } catch (_: IOException) {
                ReadwiseRequestException(ReadwiseFailure.NETWORK)
            }
            if (!error.retryable || attempt >= MAX_ATTEMPTS) throw error
            val waitSeconds = error.retryAfterSeconds ?: (BACKOFF_SECONDS shl (attempt - 1))
            if (waitSeconds > MAX_WAIT_SECONDS) throw error
            pause(waitSeconds * 1000)
            attempt++
        }
    }

    private suspend fun awaitSlot(list: Boolean) {
        val wait = maxOf(
            remaining(lastRequestAt, REQUEST_INTERVAL_MS),
            if (list) remaining(lastListRequestAt, LIST_REQUEST_INTERVAL_MS) else 0L,
        )
        if (wait > 0) pause(wait)
        val now = clock()
        lastRequestAt = now
        if (list) lastListRequestAt = now
    }

    private fun remaining(last: Long?, interval: Long): Long = last?.let { interval - (clock() - it) } ?: 0L

    companion object {
        const val MAX_ATTEMPTS = 3
        const val BACKOFF_SECONDS = 2L
        const val MAX_WAIT_SECONDS = 60L
        const val REQUEST_INTERVAL_MS = 260L
        const val LIST_REQUEST_INTERVAL_MS = 3_100L
        const val MAX_LOOKUP_PAGES = 20
    }
}
