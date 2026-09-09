package com.enve.audiobookshelf

import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.local.toBook
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.sync.ProviderSyncResult
import com.enve.core.data.sync.ProviderSyncStrategy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AudiobookshelfProgressSyncStrategy @Inject constructor(
    private val repository: AudiobookshelfRepository,
    private val connectionRegistry: ConnectionRegistry,
    private val bookCacheDao: BookCacheDao,
) : ProviderSyncStrategy {

    override val id: String = "audiobookshelf"
    override val displayName: String = "Audiobookshelf"

    @Volatile private var lastSyncAtMs: Long? = null

    override suspend fun sync(force: Boolean, launchOptimized: Boolean): ProviderSyncResult {
        val now = System.currentTimeMillis()
        if (!force && lastSyncAtMs?.let { now - it < MIN_SYNC_INTERVAL_MS } == true) {
            return ProviderSyncResult.ZERO
        }

        val connections = connectionRegistry.connections.first()
            .filter { it.enabled && it.source == BookSource.AUDIOBOOKSHELF }
        var pulled = 0
        var failed = false

        for (connection in connections) {
            val books = try {
                withContext(ConnectionScope.asContextElement(connection.id)) {
                    val localBooks = bookCacheDao.getBySourceAndConnection(
                        BookSource.AUDIOBOOKSHELF.name, connection.id,
                    ).map { it.toBook() }
                    val updated = repository.getProgressForBooks(localBooks)
                    val discovered = repository.getBooksInProgress(allowCachedFallback = false).getOrThrow()
                        .map { book ->
                            val rawLibraryId = book.libraryId
                                ?.substringAfter("::", missingDelimiterValue = book.libraryId.orEmpty())
                                ?.takeIf { it.isNotBlank() }
                            book.copy(
                                connectionId = connection.id,
                                libraryId = rawLibraryId?.let { "${connection.id}::$it" },
                            )
                        }
                    (updated + discovered).groupBy { it.uniqueKey }
                        .values.map { entries -> entries.maxBy { it.lastReadTime } }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                failed = true
                continue
            }

            for (book in books) {
                if (bookCacheDao.insertIfAbsent(book.toCachedBook(now)) != -1L) {
                    pulled++
                } else {
                    pulled += bookCacheDao.applyRemoteProgress(
                        cacheKey = book.uniqueKey,
                        source = BookSource.AUDIOBOOKSHELF.name,
                        progress = book.readProgress,
                        ebookProgress = book.epubProgress,
                        currentTimeSec = book.currentTime,
                        locatorJson = book.epubLocator,
                        finished = book.isFinished,
                        readStatus = book.serverReadStatus,
                        updatedAt = book.lastReadTime,
                    )
                }
            }
        }

        if (!failed) lastSyncAtMs = now
        return ProviderSyncResult(
            pulled = pulled,
            pushed = 0,
            failedBackends = if (failed) listOf(displayName) else emptyList(),
        )
    }

    private companion object {
        const val MIN_SYNC_INTERVAL_MS = 60_000L
    }
}
