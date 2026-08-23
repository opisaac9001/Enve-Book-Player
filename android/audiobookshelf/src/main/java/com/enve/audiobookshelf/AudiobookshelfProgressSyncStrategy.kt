package com.enve.audiobookshelf

import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.toCachedBook
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
        lastSyncAtMs = now

        val connections = connectionRegistry.connections.first()
            .filter { it.enabled && it.source == BookSource.AUDIOBOOKSHELF }
        var pulled = 0

        for (connection in connections) {
            val books = try {
                withContext(ConnectionScope.asContextElement(connection.id)) {
                    repository.getBooksInProgress().getOrThrow()
                        .map { book ->
                            val rawLibraryId = book.libraryId
                                ?.substringAfter("::", missingDelimiterValue = book.libraryId.orEmpty())
                                ?.takeIf { it.isNotBlank() }
                            book.copy(
                                connectionId = connection.id,
                                libraryId = rawLibraryId?.let { "${connection.id}::$it" },
                            )
                        }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                continue
            }

            if (books.isNotEmpty()) {
                val newBooks = mutableListOf<Book>()
                for (book in books) {
                    val existing = bookCacheDao.getByCacheKey(book.uniqueKey)
                    if (existing == null) {
                        newBooks += book
                    } else {
                        val progress = maxOf(book.readProgress, book.epubProgress ?: 0f)
                        bookCacheDao.updateUnifiedProgress(
                            bookId = book.id,
                            connectionId = connection.id,
                            progress = progress,
                            currentTimeSec = book.currentTime.takeIf { it > 0L } ?: -1L,
                            locatorJson = book.epubLocator,
                            nowMs = book.lastReadTime.takeIf { it > 0L } ?: now,
                        )
                    }
                }
                if (newBooks.isNotEmpty()) {
                    bookCacheDao.upsert(newBooks.map { it.toCachedBook(now) })
                }
                pulled += books.size
            }
        }

        return ProviderSyncResult(pulled = pulled, pushed = 0)
    }

    private companion object {
        const val MIN_SYNC_INTERVAL_MS = 60_000L
    }
}
