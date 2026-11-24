package com.enve.app.data.sync

import com.enve.app.data.repository.AggregatorRepository
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.local.PendingProgressPushDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.sync.SyncCapabilityFlag
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PendingProgressReplay @Inject constructor(
    private val pending: PendingProgressPushDao,
    private val books: BookCacheDao,
    private val connections: ConnectionRegistry,
    private val aggregator: AggregatorRepository,
    private val adapters: Set<@JvmSuppressWildcards ProviderAdapter>,
    private val serverSync: com.enve.core.data.local.ProfileServerSyncStore,
) {
    private val mutex = Mutex()

    suspend fun replay(only: PendingProgressPush? = null): Int = mutex.withLock {
        if (!serverSync.isEnabled) return@withLock 0
        var completed = 0
        val entries = if (only == null) pending.getAll() else listOfNotNull(
            pending.get(only.bookId, only.source, only.connectionKey)?.takeIf { it == only },
        )
        for (entry in entries) {
            currentCoroutineContext().ensureActive()
            if (!serverSync.accepts(entry.createdAt)) {
                pending.deleteIfUnchanged(entry.bookId, entry.source, entry.connectionKey, entry.createdAt, entry.percentage, entry.mediaType, entry.isFinished)
                continue
            }
            val source = BookSource.entries.firstOrNull { it.name == entry.source } ?: continue
            val connectionId = entry.connectionKey.takeIf(String::isNotEmpty)
            val registered = connections.getConnectionsSync()
            if (connectionId == null && registered.count { it.source == source } > 1) {
                recordFailure(entry, "The original server for this update is unknown.")
                continue
            }
            if (connectionId != null && registered.none { it.id == connectionId && it.source == source && it.enabled }) {
                recordFailure(entry, "Reconnect or enable this server to send the update.")
                continue
            }
            val cacheKey = "${connectionId ?: source.name}:${entry.bookId}"
            val cached = books.getByCacheKey(cacheKey)
                ?.takeIf { it.source == source.name && it.connectionId == connectionId }
            if (cached == null) {
                recordFailure(entry, "Refresh this book's library before retrying.")
                continue
            }
            val media = AppMediaType.entries.firstOrNull { it.name == entry.mediaType } ?: continue
            if (source == BookSource.LOCAL) {
                pending.deleteIfUnchanged(entry.bookId, entry.source, entry.connectionKey, entry.createdAt, entry.percentage, entry.mediaType, entry.isFinished)
                continue
            }
            if (adapters.none { it.source == source && it.syncCapability.supports(SyncCapabilityFlag.PUSH_PROGRESS) }) continue
            val book = cached.toBook().copy(mediaType = media)
            try {
                val result = when (media) {
                    AppMediaType.AUDIOBOOK -> aggregator.syncAudiobookProgress(book, cached.currentTime, cached.readProgress, acknowledgePending = false)
                    AppMediaType.EBOOK -> aggregator.syncEbookProgress(
                        book.id, source, cached.epubProgress ?: cached.readProgress, cached.epubLocator,
                        connectionId = connectionId,
                        observedAt = cached.lastReadTime.takeIf { it > 0 } ?: entry.createdAt,
                        persistLocalProgress = false,
                    )
                    else -> continue
                }
                result.exceptionOrNull()?.let { if (it is CancellationException) throw it }
                val unchanged = books.getByCacheKey(book.uniqueKey)
                    ?.copy(lastReadTime = cached.lastReadTime, inProgress = cached.inProgress) == cached
                if (result.isSuccess && unchanged) {
                    completed += pending.deleteIfUnchanged(entry.bookId, entry.source, entry.connectionKey, entry.createdAt, entry.percentage, entry.mediaType, entry.isFinished)
                } else if (result.isFailure) {
                    recordFailure(entry, "The server could not accept the update. Check the connection and retry.")
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                currentCoroutineContext().ensureActive()
                if (!serverSync.accepts(entry.createdAt)) {
                    pending.deleteIfUnchanged(entry.bookId, entry.source, entry.connectionKey, entry.createdAt, entry.percentage, entry.mediaType, entry.isFinished)
                } else {
                    recordFailure(entry, "The server could not accept the update. Check the connection and retry.")
                }
            }
        }
        completed
    }

    private suspend fun recordFailure(entry: PendingProgressPush, message: String) {
        pending.recordFailureIfUnchanged(entry.bookId, entry.source, entry.connectionKey,
            entry.createdAt, entry.percentage, entry.mediaType, entry.isFinished, System.currentTimeMillis(), message)
    }
}
