package com.enve.app.data.opds

import android.util.Log
import com.enve.app.data.sync.ProgressResolutionPolicy
import com.enve.app.playback.AudioPlaybackManager
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.sync.ProviderSyncResult
import com.enve.core.data.sync.ProviderSyncStrategy
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.util.runSuspendCatching
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

internal enum class OpdsProgressionDecision { NONE, PULL, PUSH }

internal fun opdsProgressionDecision(
    localPercentage: Float,
    localUpdatedAtMs: Long?,
    remote: SyncSnapshot,
    playbackSessionActive: Boolean,
): OpdsProgressionDecision =
    when (ProgressResolutionPolicy.resolve(localPercentage, localUpdatedAtMs, remote)) {
        ProgressResolutionPolicy.Decision.PULL ->
            if (playbackSessionActive) OpdsProgressionDecision.NONE else OpdsProgressionDecision.PULL

        ProgressResolutionPolicy.Decision.PUSH -> OpdsProgressionDecision.PUSH
        ProgressResolutionPolicy.Decision.NONE,
        ProgressResolutionPolicy.Decision.CONFLICT -> OpdsProgressionDecision.NONE
    }

@Singleton
class OpdsProgressionSyncStrategy @Inject constructor(
    private val service: OpdsProgressionService,
    private val bookCacheDao: BookCacheDao,
    private val connectionRegistry: ConnectionRegistry,
    private val audioPlaybackManager: AudioPlaybackManager,
) : ProviderSyncStrategy {

    override val id: String = "opds-progression"
    override val displayName: String = "OPDS Progression"

    private val minSyncIntervalMs = 60_000L

    @Volatile private var lastSyncAtMs: Long? = null

    override suspend fun sync(force: Boolean, launchOptimized: Boolean): ProviderSyncResult {
        val now = System.currentTimeMillis()
        if (!force) {
            val last = lastSyncAtMs
            if (last != null && now - last < minSyncIntervalMs) return ProviderSyncResult.ZERO
        }
        lastSyncAtMs = now

        val connections = connectionRegistry.connections.first()
            .filter { it.enabled && it.source == BookSource.OPDS }
        if (connections.isEmpty()) return ProviderSyncResult.ZERO

        val perConnectionLimit = if (launchOptimized) LAUNCH_LIMIT else FULL_LIMIT

        var pulled = 0
        var pushed = 0
        for (connection in connections) {
            val books = runSuspendCatching {
                bookCacheDao.getInProgressWithProgressionService(
                    source = BookSource.OPDS.name,
                    connectionId = connection.id,
                    limit = perConnectionLimit,
                )
            }.getOrDefault(emptyList())
            if (books.isEmpty()) continue
            withContext(ConnectionScope.asContextElement(connection.id)) {
                for (cached in books) {
                    try {
                        when (reconcile(cached)) {
                            OpdsProgressionDecision.PULL -> pulled += 1
                            OpdsProgressionDecision.PUSH -> pushed += 1
                            OpdsProgressionDecision.NONE -> Unit
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        Log.w(TAG, "OPDS progression sync failed for \"${cached.title}\": ${e.javaClass.simpleName}")
                    }
                }
            }
            connectionRegistry.setLastSynced(connection.id, System.currentTimeMillis())
        }
        return ProviderSyncResult(pulled = pulled, pushed = pushed)
    }

    private suspend fun reconcile(cached: CachedBook): OpdsProgressionDecision {
        val book = cached.toBook()
        val localPercentage = localPercentage(book)
        val localUpdatedAt = cached.lastReadTime.takeIf { it > 0L }
        val remote = service.fetch(book) ?: return when {
            localPercentage > 0.001f -> push(book, localPercentage)
            else -> OpdsProgressionDecision.NONE
        }

        return when (opdsProgressionDecision(localPercentage, localUpdatedAt, remote, playbackSessionActive(book))) {
            OpdsProgressionDecision.PULL -> {
                apply(book, remote)
                OpdsProgressionDecision.PULL
            }

            OpdsProgressionDecision.PUSH -> push(book, localPercentage)
            OpdsProgressionDecision.NONE -> OpdsProgressionDecision.NONE
        }
    }

    private fun playbackSessionActive(book: Book): Boolean =
        book.mediaType != AppMediaType.EBOOK && audioPlaybackManager.currentBookId == book.id

    private suspend fun push(book: Book, localPercentage: Float): OpdsProgressionDecision {
        val result = service.push(
            book = book,
            percentage = localPercentage,
            currentTimeSec = book.currentTime.takeIf { book.mediaType != AppMediaType.EBOOK && it > 0L },
            locatorJson = book.epubLocator,
            page = null,
        )
        return when (result) {
            OpdsProgressionPushResult.Written -> OpdsProgressionDecision.PUSH
            OpdsProgressionPushResult.Superseded -> pullSuperseded(book)
            OpdsProgressionPushResult.Skipped -> OpdsProgressionDecision.NONE
            is OpdsProgressionPushResult.Failed -> {
                Log.w(TAG, "OPDS progression push rejected for \"${book.title}\": ${result.reason}")
                OpdsProgressionDecision.NONE
            }
        }
    }

    private suspend fun pullSuperseded(book: Book): OpdsProgressionDecision {
        if (playbackSessionActive(book)) return OpdsProgressionDecision.NONE
        val newer = service.fetch(book) ?: return OpdsProgressionDecision.NONE
        apply(book, newer)
        return OpdsProgressionDecision.PULL
    }

    private suspend fun apply(book: Book, snapshot: SyncSnapshot) {
        val nowMs = snapshot.updatedAt ?: System.currentTimeMillis()
        if (snapshot.finished) {
            bookCacheDao.updateFinishedStatus(
                bookId = book.id,
                connectionId = book.connectionId,
                finished = true,
                nowMs = nowMs,
            )
            return
        }
        bookCacheDao.updateUnifiedProgress(
            bookId = book.id,
            connectionId = book.connectionId,
            progress = snapshot.percentage,
            currentTimeSec = snapshot.positionMs?.let { it / 1000L } ?: -1L,
            locatorJson = snapshot.locatorJson,
            nowMs = nowMs,
        )
    }

    private fun localPercentage(book: Book): Float = when (book.mediaType) {
        AppMediaType.EBOOK -> (book.epubProgress ?: book.readProgress).coerceIn(0f, 1f)
        else -> book.progress.coerceIn(0f, 1f)
    }

    private companion object {
        const val TAG = "OpdsProgressionSync"
        const val LAUNCH_LIMIT = 12
        const val FULL_LIMIT = 40
    }
}
