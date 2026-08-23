package com.enve.bookorbit.sync

import android.util.Log
import com.enve.bookorbit.BookOrbitProviderAdapter
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
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
class BookOrbitSyncStrategy @Inject constructor(
    private val adapter: BookOrbitProviderAdapter,
    private val bookCacheDao: BookCacheDao,
    private val connectionRegistry: ConnectionRegistry,
    private val historySync: BookOrbitHistorySessionSync,
    private val readerArtifactSync: BookOrbitReaderArtifactSync,
) : ProviderSyncStrategy {
    override val id: String = "bookorbit"
    override val displayName: String = "BookOrbit"

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
            .filter { it.enabled && it.source == BookSource.BOOKORBIT }
        if (connections.isEmpty()) return ProviderSyncResult.ZERO

        var pulled = 0
        var pushed = 0
        for (connection in connections) {
            try {
                val cachedBooks = bookCacheDao.getBySourceAndConnection(
                    source = BookSource.BOOKORBIT.name,
                    connectionId = connection.id,
                ).map { it.toBook() }
                val booksByKey = cachedBooks.associateBy(Book::uniqueKey)
                val continueBooks = withContext(ConnectionScope.asContextElement(connection.id)) {
                    adapter.getContinueListening().getOrDefault(emptyList()) +
                        adapter.getContinueReading().getOrDefault(emptyList())
                }

                if (!launchOptimized) {
                    val activity = withContext(ConnectionScope.asContextElement(connection.id)) {
                        fetchAllBooks()
                    }
                    val nowMs = System.currentTimeMillis()
                    for (remote in activity) {
                        val existing = bookCacheDao.getByCacheKey(
                            remote.copy(connectionId = connection.id).uniqueKey,
                        ) ?: continue
                        val status = remote.serverReadStatus
                        if (existing.personalRating != remote.personalRating ||
                            existing.serverReadStatus != status
                        ) {
                            bookCacheDao.updateBookOrbitUserData(
                                bookId = remote.id,
                                connectionId = connection.id,
                                rating = remote.personalRating,
                                serverReadStatus = status,
                                nowMs = nowMs,
                            )
                            pulled += 1
                        }
                    }
                }

                val nowMs = System.currentTimeMillis()
                for (book in continueBooks.distinctBy { it.uniqueKey }) {
                    try {
                        val remote = book.copy(
                            source = BookSource.BOOKORBIT,
                            connectionId = connection.id,
                        )
                        val existing = bookCacheDao.getByCacheKey(remote.uniqueKey)
                        if (existing == null) {
                            val cached = remote.toCachedBook(nowMs).let { row ->
                                if (remote.lastReadTime > 0L) row else row.copy(lastReadTime = 0L)
                            }
                            bookCacheDao.upsert(listOf(cached))
                            pulled += 1
                            continue
                        }

                        val local = existing.toBook()
                        val localProgress = local.syncProgress()
                        val remoteProgress = remote.syncProgress()
                        when (
                            BookOrbitProgressResolver.resolve(
                                localPercentage = localProgress,
                                localUpdatedAt = local.lastReadTime.takeIf { it > 0L },
                                remotePercentage = remoteProgress,
                                remoteUpdatedAt = remote.lastReadTime.takeIf { it > 0L },
                            )
                        ) {
                            BookOrbitProgressDecision.PULL -> {
                                bookCacheDao.updateUnifiedProgress(
                                    bookId = remote.id,
                                    connectionId = connection.id,
                                    progress = remoteProgress,
                                    currentTimeSec = remote.currentTime
                                        .takeIf { remote.mediaType != AppMediaType.EBOOK }
                                        ?: -1L,
                                    locatorJson = remote.epubLocator,
                                    nowMs = remote.lastReadTime.takeIf { it > 0L } ?: 0L,
                                )
                                pulled += 1
                            }
                            BookOrbitProgressDecision.PUSH -> {
                                val result = withContext(ConnectionScope.asContextElement(connection.id)) {
                                    if (local.mediaType == AppMediaType.EBOOK) {
                                        adapter.syncEbookProgress(
                                            bookId = local.id,
                                            percentage = localProgress,
                                            locator = local.epubLocator,
                                        )
                                    } else {
                                        adapter.syncAudiobookProgress(
                                            book = local,
                                            currentTimeSec = local.currentTime,
                                            progressFraction = localProgress,
                                        )
                                    }
                                }
                                if (result.isSuccess) pushed += 1
                            }
                            BookOrbitProgressDecision.NONE,
                            BookOrbitProgressDecision.CONFLICT -> Unit
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (error: Exception) {
                        Log.w(TAG, "Failed to reconcile BookOrbit progress for ${book.id}: ${error.message}")
                    }
                }

                withContext(ConnectionScope.asContextElement(connection.id)) {
                    pushed += historySync.retry(connection.id, booksByKey)
                    val userDataBooks = if (launchOptimized) {
                        continueBooks.mapNotNull { remote -> booksByKey[remote.copy(connectionId = connection.id).uniqueKey] }
                    } else {
                        cachedBooks
                    }.distinctBy(Book::uniqueKey)
                    for (book in userDataBooks) {
                        try {
                            if (!launchOptimized) pulled += historySync.pull(connection.id, book)
                            val result = readerArtifactSync.sync(book)
                            pulled += result.pulled
                            pushed += result.pushed
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to sync BookOrbit user data for ${book.id}: ${e.message}")
                        }
                    }
                }
                connectionRegistry.setLastSynced(connection.id, System.currentTimeMillis())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "BookOrbit sync failed for connection=${connection.id}: ${e.message}")
            }
        }
        return ProviderSyncResult(pulled = pulled, pushed = pushed)
    }

    private suspend fun fetchAllBooks(): List<Book> {
        val books = mutableListOf<Book>()
        for (library in adapter.getLibraries().getOrThrow()) {
            var page = 0
            while (true) {
                val batch = adapter.getBooks(
                    libraryId = library.id,
                    page = page,
                    size = USER_DATA_PAGE_SIZE,
                ).getOrThrow()
                books += batch
                if (batch.size < USER_DATA_PAGE_SIZE) break
                page += 1
            }
        }
        return books.distinctBy(Book::uniqueKey)
    }

    private fun Book.syncProgress(): Float = when (mediaType) {
        AppMediaType.EBOOK -> (epubProgress ?: readProgress).coerceIn(0f, 1f)
        else -> progress.coerceIn(0f, 1f)
    }

    private companion object {
        const val TAG = "BookOrbitSyncStrategy"
        const val USER_DATA_PAGE_SIZE = 200
    }
}
