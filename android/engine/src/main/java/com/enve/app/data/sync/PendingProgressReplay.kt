package com.enve.app.data.sync

import com.enve.app.data.repository.AggregatorRepository
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
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

    suspend fun replay(): Int = mutex.withLock {
        if (!serverSync.isEnabled) return@withLock 0
        var completed = 0
        for (entry in pending.getAll()) {
            currentCoroutineContext().ensureActive()
            if (!serverSync.accepts(entry.createdAt)) {
                pending.deleteIfUnchanged(entry.bookId, entry.source, entry.connectionKey, entry.createdAt, entry.percentage)
                continue
            }
            val source = BookSource.entries.firstOrNull { it.name == entry.source } ?: continue
            val connectionId = entry.connectionKey.takeIf(String::isNotEmpty)
            if (connectionId != null && connections.getConnectionsSync().none { it.id == connectionId && it.source == source && it.enabled }) continue
            val cacheKey = "${connectionId ?: source.name}:${entry.bookId}"
            val cached = books.getByCacheKey(cacheKey)
                ?.takeIf { it.source == source.name && it.connectionId == connectionId } ?: continue
            val media = AppMediaType.entries.firstOrNull { it.name == entry.mediaType } ?: continue
            if (source == BookSource.LOCAL) {
                pending.deleteIfUnchanged(entry.bookId, entry.source, entry.connectionKey, entry.createdAt, entry.percentage)
                continue
            }
            if (adapters.none { it.source == source && it.syncCapability.supports(SyncCapabilityFlag.PUSH_PROGRESS) }) continue
            val book = cached.toBook().copy(mediaType = media)
            try {
                val result = when (media) {
                    AppMediaType.AUDIOBOOK -> aggregator.syncAudiobookProgress(book, cached.currentTime, cached.readProgress, acknowledgePending = false)
                    AppMediaType.EBOOK -> aggregator.syncEbookProgress(book.id, source, cached.epubProgress ?: cached.readProgress, cached.epubLocator, connectionId = connectionId)
                    else -> continue
                }
                result.exceptionOrNull()?.let { if (it is CancellationException) throw it }
                if (result.isSuccess && books.getByCacheKey(book.uniqueKey) == cached) {
                    completed += pending.deleteIfUnchanged(entry.bookId, entry.source, entry.connectionKey, entry.createdAt, entry.percentage)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                currentCoroutineContext().ensureActive()
                if (!serverSync.accepts(entry.createdAt)) {
                    pending.deleteIfUnchanged(entry.bookId, entry.source, entry.connectionKey, entry.createdAt, entry.percentage)
                }
            }
        }
        completed
    }
}
