package com.enve.app.data.sync

import com.enve.core.data.util.runSuspendCatching
import android.util.Log
import androidx.room.withTransaction
import com.enve.app.data.local.ReaderDatabase
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.app.data.repository.AggregatorRepository
import com.enve.core.data.sync.ProviderSyncStrategy
import com.enve.core.data.sync.ProviderSyncResult
import com.enve.core.data.sync.SyncSnapshot
import javax.inject.Inject
import javax.inject.Singleton

internal fun appliesRemoteAudiobookProgress(snapshot: SyncSnapshot, decision: ProgressResolutionPolicy.Decision): Boolean =
    decision == ProgressResolutionPolicy.Decision.PULL ||
        (snapshot.finished && decision == ProgressResolutionPolicy.Decision.NONE)

@Singleton
class GrimmoryAudiobookSyncStrategy @Inject constructor(
    private val aggregatorRepository: AggregatorRepository,
    private val bookCacheDao: BookCacheDao,
    private val database: ReaderDatabase,
) : ProviderSyncStrategy {

    override val id: String = "grimmory-audiobook"
    override val displayName: String = "Grimmory (Audiobook)"

    private val minSyncIntervalMs = 60_000L
    @Volatile private var lastSyncAtMs: Long? = null

    override suspend fun sync(force: Boolean, launchOptimized: Boolean): ProviderSyncResult {
        val startedAt = System.currentTimeMillis()
        if (!force) {
            val last = lastSyncAtMs
            if (last != null && startedAt - last < minSyncIntervalMs) return ProviderSyncResult.ZERO
        }

        val limit = if (launchOptimized) 12 else 40
        val cached = runSuspendCatching { bookCacheDao.getInProgressOnce(limit = limit) }
            .getOrDefault(emptyList())
            .filter { it.source == BookSource.GRIMMORY.name && it.mediaType == AppMediaType.AUDIOBOOK.name }

        val localKeys = cached.map { "${it.connectionId ?: it.source}:${it.id}" }.toSet()
        val homeSnapshot = runSuspendCatching { aggregatorRepository.getHomeSnapshot().getOrThrow() }
        var complete = homeSnapshot.isSuccess
        val serverOnly = homeSnapshot.getOrNull()?.continueListening.orEmpty()
            .filter { it.source == BookSource.GRIMMORY && it.mediaType == AppMediaType.AUDIOBOOK }
            .filter { "${it.connectionId ?: it.source.name}:${it.id}" !in localKeys }
            .take(20)

        val candidates = LinkedHashMap<String, com.enve.core.data.model.Book>()
        cached.map { it.toBook() }.forEach { candidates[it.uniqueKey] = it }
        serverOnly.forEach { candidates.putIfAbsent(it.uniqueKey, it) }

        var pulled = 0
        for (book in candidates.values) {
            val fetched = aggregatorRepository.fetchAudiobookProgress(book)
            if (fetched.isFailure) complete = false
            val snapshot = fetched.getOrNull() ?: continue

            runSuspendCatching {
                database.withTransaction {
                    val localRow = bookCacheDao.getByIdAndConnection(book.id, book.connectionId)
                    val decision = ProgressResolutionPolicy.resolve(
                        localPercentage = localRow?.readProgress ?: 0f,
                        localUpdatedAt = localRow?.lastReadTime?.takeIf { it > 0L },
                        remote = snapshot,
                    )
                    if (decision == ProgressResolutionPolicy.Decision.CONFLICT) {
                        Log.i(TAG, "Kept local progress for ${book.title}; remote ${(snapshot.percentage * 100).toInt()}% conflicts")
                        return@withTransaction
                    }
                    if (!appliesRemoteAudiobookProgress(snapshot, decision)) return@withTransaction

                    val observedAt = snapshot.updatedAt ?: localRow?.lastReadTime ?: 0L
                    if (snapshot.finished) {
                        bookCacheDao.updateFinishedStatus(
                            bookId = book.id,
                            connectionId = book.connectionId,
                            finished = true,
                            nowMs = observedAt,
                        )
                    } else {
                        bookCacheDao.updateUnifiedProgress(
                            bookId = book.id,
                            connectionId = book.connectionId,
                            progress = snapshot.percentage,
                            currentTimeSec = snapshot.positionMs?.let { it / 1000 } ?: -1L,
                            locatorJson = null,
                            nowMs = observedAt,
                        )
                    }
                    pulled += 1
                    Log.i(TAG, "Pulled ${book.title}: ${(snapshot.percentage * 100).toInt()}%${if (snapshot.finished) " (finished)" else ""}")
                }
            }.onFailure { complete = false }
        }

        if (complete) lastSyncAtMs = startedAt
        return ProviderSyncResult(pulled = pulled, pushed = 0)
    }

    private companion object { const val TAG = "GrimmoryAudiobookSyncStrategy" }
}
