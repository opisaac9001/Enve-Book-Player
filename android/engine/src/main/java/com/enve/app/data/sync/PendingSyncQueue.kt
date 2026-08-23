package com.enve.app.data.sync

import android.content.Context
import android.util.Log
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

private const val TAG = "PendingSyncQueue"
private const val MAX_RETRIES = 10
private const val QUEUE_FILE = "pending_sync_queue.json"

@Singleton
class PendingSyncQueue @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val queue = ConcurrentLinkedQueue<PendingItem>()
    private val isFlushing = AtomicBoolean(false)

    @Serializable
    data class PendingItem(
        val bookId: String,
        val mediaType: String,
        val percentage: Float,
        val positionMs: Long? = null,
        val locatorJson: String? = null,
        val retries: Int = 0,
        val enqueuedAt: Long = System.currentTimeMillis(),
    )

    enum class FailureClass { Auth, Permanent, Transient }

    init {
        loadFromDisk()
    }

    fun enqueue(
        book: Book,
        percentage: Float,
        positionMs: Long? = null,
        locatorJson: String? = null,
    ) {
        val existing = queue.firstOrNull { it.bookId == book.id }
        if (existing != null) {
            queue.remove(existing)
        }
        queue.add(
            PendingItem(
                bookId = book.id,
                mediaType = book.mediaType.name,
                percentage = percentage,
                positionMs = positionMs,
                locatorJson = locatorJson,
            )
        )
        saveToDisk()
    }

    fun remove(bookId: String) {
        queue.removeIf { it.bookId == bookId }
        saveToDisk()
    }

    fun pendingCount(): Int = queue.size

    fun pendingItems(): List<PendingItem> = queue.toList()

    suspend fun flush(push: suspend (PendingItem) -> Result<Unit>) {
        if (!isFlushing.compareAndSet(false, true)) return
        try {
            val items = queue.toList()
            for (item in items) {
                val result = push(item)
                result.fold(
                    onSuccess = { queue.remove(item) },
                    onFailure = { error ->
                        val failClass = classifyFailure(error)
                        when (failClass) {
                            FailureClass.Auth, FailureClass.Permanent -> {
                                Log.w(TAG, "Dropping pending item ${item.bookId}: $failClass ($error)")
                                queue.remove(item)
                            }
                            FailureClass.Transient -> {
                                if (item.retries >= MAX_RETRIES) {
                                    Log.w(TAG, "Max retries reached for ${item.bookId}, dropping")
                                    queue.remove(item)
                                } else {
                                    queue.remove(item)
                                    queue.add(item.copy(retries = item.retries + 1))
                                    val backoffMs = (1000L * (1 shl item.retries)).coerceAtMost(300_000L)
                                    delay(backoffMs)
                                }
                            }
                        }
                    }
                )
            }
            saveToDisk()
        } finally {
            isFlushing.set(false)
        }
    }

    private fun classifyFailure(error: Throwable): FailureClass {
        val message = error.message ?: ""
        return when {
            message.contains("401") || message.contains("403") -> FailureClass.Auth
            message.contains("404") || message.contains("410") || message.contains("422") -> FailureClass.Permanent
            else -> FailureClass.Transient
        }
    }

    private fun queueFile(): File = File(context.filesDir, QUEUE_FILE)

    private fun saveToDisk() {
        runCatching {
            queueFile().writeText(json.encodeToString(queue.toList()))
        }.onFailure { Log.e(TAG, "Failed to save queue", it) }
    }

    private fun loadFromDisk() {
        runCatching {
            val file = queueFile()
            if (!file.exists()) return
            val items = json.decodeFromString<List<PendingItem>>(file.readText())
            queue.addAll(items)
            Log.d(TAG, "Loaded ${items.size} pending items from disk")
        }.onFailure { Log.e(TAG, "Failed to load queue", it) }
    }
}
