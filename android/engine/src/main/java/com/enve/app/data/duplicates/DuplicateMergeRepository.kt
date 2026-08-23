package com.enve.app.data.duplicates

import androidx.room.withTransaction
import com.enve.app.data.local.ReaderDatabase
import com.enve.core.data.local.BookMetadataOverride
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.model.DuplicateBookCluster
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.max
import kotlin.math.min

data class DuplicateMergeResult(
    val keepBookKey: String,
    val removedBookKeys: List<String>,
    val title: String,
)

@Singleton
class DuplicateMergeRepository @Inject constructor(
    private val db: ReaderDatabase,
) {
    private val bookCacheDao = db.bookCacheDao()
    private val bookExtrasDao = db.bookExtrasDao()
    private val metadataOverrideDao = db.bookMetadataOverrideDao()
    private val linkedBookPairDao = db.linkedBookPairDao()
    private val userCollectionDao = db.userCollectionDao()
    private val annotationDao = db.annotationDao()
    private val vocabEntryDao = db.vocabEntryDao()
    private val pendingProgressPushDao = db.pendingProgressPushDao()

    suspend fun mergeCluster(
        cluster: DuplicateBookCluster,
        keepBookKey: String,
    ): DuplicateMergeResult = withContext(Dispatchers.IO) {
        val clusterKeys = cluster.books.map { it.uniqueKey }.distinct()
        require(keepBookKey in clusterKeys) { "Keeper is not part of this duplicate cluster" }

        db.withTransaction {
            val rows = clusterKeys.mapNotNull { bookCacheDao.getByCacheKey(it) }
            val keeper = rows.firstOrNull { it.cacheKey == keepBookKey }
                ?: error("Kept book is no longer cached")
            val losers = rows.filterNot { it.cacheKey == keepBookKey }
            if (losers.isEmpty()) {
                return@withTransaction DuplicateMergeResult(
                    keepBookKey = keepBookKey,
                    removedBookKeys = emptyList(),
                    title = keeper.title,
                )
            }

            val now = System.currentTimeMillis()
            val merged = mergeRows(keeper, rows, now)
            bookCacheDao.upsert(listOf(merged))
            metadataOverrideDao.upsert(merged.toMetadataOverride(now))

            for (loser in losers) {
                try {
                    moveLocalReferences(source = loser, target = keeper, now = now)
                } catch (e: CancellationException) {
                    throw e
                }
            }

            val loserKeys = losers.map { it.cacheKey }
            metadataOverrideDao.deleteForBooks(loserKeys)
            bookCacheDao.deleteByCacheKeys(loserKeys)

            DuplicateMergeResult(
                keepBookKey = keepBookKey,
                removedBookKeys = loserKeys,
                title = merged.title,
            )
        }
    }

    private suspend fun moveLocalReferences(source: CachedBook, target: CachedBook, now: Long) {
        annotationDao.moveBook(source.cacheKey, target.cacheKey, now)
        vocabEntryDao.moveBookEntries(source.cacheKey, target.cacheKey)
        userCollectionDao.copyBookMemberships(source.cacheKey, target.cacheKey)
        userCollectionDao.removeBookFromAllCollections(source.cacheKey)
        moveLinkedPairReferences(source.cacheKey, target.cacheKey, now)
        moveBookExtras(source.cacheKey, target.cacheKey, now)
        movePendingProgress(source, target)
    }

    private suspend fun moveLinkedPairReferences(sourceKey: String, targetKey: String, now: Long) {
        linkedBookPairDao.getForEbook(sourceKey)?.let { pair ->
            if (linkedBookPairDao.getForEbook(targetKey) == null) {
                linkedBookPairDao.upsert(pair.copy(ebookKey = targetKey, updatedAt = now))
            }
            linkedBookPairDao.deleteForEbook(sourceKey)
        }

        linkedBookPairDao.getForAudiobook(sourceKey)?.let { pair ->
            if (linkedBookPairDao.getForAudiobook(targetKey) == null) {
                linkedBookPairDao.upsert(pair.copy(audiobookKey = targetKey, updatedAt = now))
            }
            linkedBookPairDao.deleteForAudiobook(sourceKey)
        }
    }

    private suspend fun moveBookExtras(sourceKey: String, targetKey: String, now: Long) {
        val sourceExtras = bookExtrasDao.get(sourceKey) ?: return
        val targetExtras = bookExtrasDao.get(targetKey)
        if (targetExtras == null) {
            bookExtrasDao.upsert(sourceExtras.copy(cacheKey = targetKey, updatedAt = now))
        } else {
            val merged = targetExtras.copy(
                chaptersJson = targetExtras.chaptersJson.takeUnless { it.isEmptyJsonArray() } ?: sourceExtras.chaptersJson,
                audioTracksJson = targetExtras.audioTracksJson.takeUnless { it.isEmptyJsonArray() } ?: sourceExtras.audioTracksJson,
                updatedAt = max(max(targetExtras.updatedAt, sourceExtras.updatedAt), now),
            )
            if (merged != targetExtras) {
                bookExtrasDao.upsert(merged)
            }
        }
        bookExtrasDao.delete(sourceKey)
    }

    private suspend fun movePendingProgress(source: CachedBook, target: CachedBook) {
        if (source.source != target.source || source.connectionId != target.connectionId) return
        val queueSource = source.source
        val connectionKey = source.connectionId.orEmpty()
        val sourceToTargetIds = listOf(
            source.cacheKey to target.cacheKey,
            source.id to target.id,
        ).distinct()

        for ((sourceId, targetId) in sourceToTargetIds) {
            if (sourceId == targetId) continue
            val sourcePush = pendingProgressPushDao.get(sourceId, queueSource, connectionKey) ?: continue
            val moved = sourcePush.copy(bookId = targetId)
            val existing = pendingProgressPushDao.get(targetId, queueSource, connectionKey)
            pendingProgressPushDao.upsert(mergePendingProgress(existing, moved))
            pendingProgressPushDao.delete(sourceId, queueSource, connectionKey)
        }
    }

    private fun mergePendingProgress(existing: PendingProgressPush?, moved: PendingProgressPush): PendingProgressPush {
        if (existing == null) return moved
        val keepMoved = moved.percentage > existing.percentage ||
            (moved.percentage == existing.percentage && moved.lastAttemptAt >= existing.lastAttemptAt)
        val selected = if (keepMoved) moved else existing
        return selected.copy(
            createdAt = min(existing.createdAt, moved.createdAt),
            attempts = max(existing.attempts, moved.attempts),
            lastAttemptAt = max(existing.lastAttemptAt, moved.lastAttemptAt),
            isFinished = existing.isFinished || moved.isFinished,
            lastError = selected.lastError ?: existing.lastError ?: moved.lastError,
        )
    }

    private fun mergeRows(keeper: CachedBook, rows: List<CachedBook>, now: Long): CachedBook {
        val duration = keeper.duration.takeIf { it > 0L } ?: rows.maxOf { it.duration }
        val readProgress = rows.maxOf { progressFraction(it) }.coerceIn(0f, 1f)
        val epubProgress = rows.mapNotNull { it.epubProgress }.maxOrNull()
        val currentTime = rows.maxOf { it.currentTime }
        val finished = rows.any { it.isFinished || it.readProgress >= 0.99f || (it.epubProgress ?: 0f) >= 0.99f }
        val hideFromContinue = rows.all { it.hideFromContinue }
        val inProgress = !finished && !hideFromContinue && (
            readProgress in 0.01f..0.99f ||
                (epubProgress ?: 0f) in 0.01f..0.99f ||
                currentTime > 0L
            )

        return keeper.copy(
            title = keeper.title.takeIf { it.isNotBlank() } ?: rows.firstNonBlank { it.title }.orEmpty(),
            subtitle = keeper.subtitle.nonBlank() ?: rows.firstNonBlank { it.subtitle },
            author = keeper.author.nonBlank() ?: rows.firstNonBlank { it.author },
            narrator = keeper.narrator.nonBlank() ?: rows.firstNonBlank { it.narrator },
            coverUrl = keeper.coverUrl.nonBlank() ?: rows.firstNonBlank { it.coverUrl },
            duration = duration,
            currentTime = currentTime,
            isFinished = finished,
            readProgress = readProgress,
            epubProgress = epubProgress ?: keeper.epubProgress,
            epubLocator = keeper.epubLocator.nonBlank() ?: rows.firstNonBlank { it.epubLocator },
            lastReadTime = rows.maxOf { it.lastReadTime },
            addedOn = keeper.addedOn.takeIf { it > 0L } ?: rows.map { it.addedOn }.filter { it > 0L }.minOrNull().orZero(),
            seriesName = keeper.seriesName.nonBlank() ?: rows.firstNonBlank { it.seriesName },
            seriesNumber = keeper.seriesNumber.nonBlank() ?: rows.firstNonBlank { it.seriesNumber },
            publisher = keeper.publisher.nonBlank() ?: rows.firstNonBlank { it.publisher },
            publishedDate = keeper.publishedDate.nonBlank() ?: rows.firstNonBlank { it.publishedDate },
            description = rows.longestText { it.description } ?: keeper.description,
            language = keeper.language.nonBlank() ?: rows.firstNonBlank { it.language },
            pageCount = keeper.pageCount?.takeIf { it > 0 } ?: rows.mapNotNull { it.pageCount?.takeIf { pages -> pages > 0 } }.maxOrNull(),
            isDownloaded = rows.any { it.isDownloaded },
            hideFromContinue = hideFromContinue,
            readAlongAvailable = rows.any { it.readAlongAvailable },
            categoriesJson = mergedCategoriesJson(rows),
            isbn13 = keeper.isbn13.nonBlank() ?: rows.firstNonBlank { it.isbn13 },
            personalRating = keeper.personalRating ?: rows.mapNotNull { it.personalRating }.maxOrNull(),
            goodreadsRating = keeper.goodreadsRating ?: rows.mapNotNull { it.goodreadsRating }.maxOrNull(),
            primaryFileType = keeper.primaryFileType.nonBlank() ?: rows.firstNonBlank { it.primaryFileType },
            inProgress = inProgress,
            cachedAt = now,
            narratorEnrichedAt = rows.maxOf { it.narratorEnrichedAt },
        )
    }

    private fun progressFraction(row: CachedBook): Float {
        val audioProgress = if (row.duration > 0L && row.currentTime > 0L) {
            row.currentTime.toFloat() / row.duration.toFloat()
        } else {
            row.readProgress
        }
        return max(audioProgress, row.epubProgress ?: 0f)
    }

    private fun mergedCategoriesJson(rows: List<CachedBook>): String {
        val categories = rows
            .flatMap { row ->
                runCatching {
                    json.decodeFromString(ListSerializer(String.serializer()), row.categoriesJson)
                }.getOrDefault(emptyList())
            }
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinctBy { it.lowercase() }
        return json.encodeToString(ListSerializer(String.serializer()), categories)
    }

    private fun CachedBook.toMetadataOverride(now: Long): BookMetadataOverride =
        BookMetadataOverride(
            bookKey = cacheKey,
            title = title,
            subtitle = subtitle,
            author = author,
            narrator = narrator,
            description = description,
            seriesName = seriesName,
            seriesNumber = seriesNumber,
            publisher = publisher,
            publishedDate = publishedDate,
            isbn13 = isbn13,
            language = language,
            pageCount = pageCount,
            updatedAt = now,
        )

    private fun List<CachedBook>.firstNonBlank(selector: (CachedBook) -> String?): String? =
        asSequence().mapNotNull { selector(it).nonBlank() }.firstOrNull()

    private fun List<CachedBook>.longestText(selector: (CachedBook) -> String?): String? =
        asSequence().mapNotNull { selector(it).nonBlank() }.maxByOrNull { it.length }

    private fun String?.nonBlank(): String? = this?.trim()?.takeIf { it.isNotEmpty() }

    private fun Long?.orZero(): Long = this ?: 0L

    private fun String.isEmptyJsonArray(): Boolean = trim() == "[]"

    companion object {
        private val json = Json { ignoreUnknownKeys = true }
    }
}
