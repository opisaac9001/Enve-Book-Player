package com.enve.core.data.local

import androidx.room.*
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ReadStatus
import kotlinx.coroutines.flow.Flow

@Entity(
    tableName = "book_cache",
    indices = [
        Index("connectionId"),
        Index("source"),
        Index("mediaType"),
        Index("lastReadTime"),
        Index("addedOn"),
        Index("isFinished"),
        Index("readProgress"),
        Index("inProgress"),
    ],
)
data class CachedBook(
    @PrimaryKey val cacheKey: String,
    val id: String,
    val connectionId: String?,
    val source: String,
    val mediaType: String,
    val title: String,
    val author: String?,
    val narrator: String?,
    val coverUrl: String?,
    val duration: Long,
    val currentTime: Long,
    val isFinished: Boolean,
    val readProgress: Float,
    val epubProgress: Float?,
    val epubLocator: String?,
    val lastReadTime: Long,
    val addedOn: Long,
    val libraryId: String?,
    val libraryName: String?,
    val seriesName: String?,
    val seriesNumber: String?,
    val publisher: String?,
    val publishedDate: String?,
    val description: String?,
    val language: String?,
    val pageCount: Int?,
    val isDownloaded: Boolean,
    val hideFromContinue: Boolean,
    val readAlongAvailable: Boolean,
    val hasAudio: Boolean = false,
    val hasEbook: Boolean = false,
    val categoriesJson: String,
    val subtitle: String?,
    val isbn13: String?,
    val personalRating: Float?,
    val goodreadsRating: Float?,
    val primaryFileType: String?,

    val inProgress: Boolean,

    val cachedAt: Long,

    val narratorEnrichedAt: Long = 0L,
    val serverReadStatus: String? = null,
)

@Dao
interface BookCacheDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(books: List<CachedBook>)

    @Query("UPDATE book_cache SET epubLocator = :locatorJson, epubProgress = :progress WHERE id = :bookId AND (connectionId = :connectionId OR (:connectionId IS NULL AND connectionId IS NULL))")
    suspend fun updateEpubProgress(bookId: String, connectionId: String?, locatorJson: String?, progress: Float)

    @Query("""
        SELECT * FROM book_cache
        WHERE id = :bookId
          AND (connectionId = :connectionId OR (:connectionId IS NULL AND connectionId IS NULL))
        LIMIT 1
    """)
    suspend fun getByIdAndConnection(bookId: String, connectionId: String?): CachedBook?

    @Query("SELECT * FROM book_cache WHERE id = :bookId LIMIT 1")
    suspend fun getById(bookId: String): CachedBook?

    @Query("SELECT * FROM book_cache WHERE id = :bookId LIMIT 1")
    fun observeById(bookId: String): Flow<CachedBook?>

    @Query("SELECT * FROM book_cache WHERE cacheKey = :cacheKey LIMIT 1")
    suspend fun getByCacheKey(cacheKey: String): CachedBook?

    @Query("SELECT * FROM book_cache WHERE cacheKey = :cacheKey LIMIT 1")
    fun observeByCacheKey(cacheKey: String): Flow<CachedBook?>

    @Query("SELECT * FROM book_cache WHERE cacheKey IN (:cacheKeys)")
    suspend fun getByCacheKeys(cacheKeys: List<String>): List<CachedBook>

    @Query("SELECT * FROM book_cache WHERE source = :source AND connectionId = :connectionId")
    suspend fun getBySourceAndConnection(source: String, connectionId: String): List<CachedBook>

    @Query("SELECT * FROM book_cache WHERE mediaType = 'AUDIOBOOK' AND id IN (:bookIds)")
    suspend fun getAudiobooksByIds(bookIds: List<String>): List<CachedBook>

    @Query("""
        UPDATE book_cache
        SET title = :title,
            subtitle = :subtitle,
            author = :author,
            narrator = :narrator,
            coverUrl = :coverUrl,
            duration = :duration,
            description = :description,
            seriesName = :seriesName,
            seriesNumber = :seriesNumber,
            publisher = :publisher,
            publishedDate = :publishedDate,
            isbn13 = :isbn13,
            language = :language,
            pageCount = :pageCount,
            categoriesJson = :categoriesJson,
            cachedAt = :nowMs
        WHERE cacheKey = :bookKey
    """)
    suspend fun updateLocalMetadata(
        bookKey: String,
        title: String,
        subtitle: String?,
        author: String?,
        narrator: String?,
        coverUrl: String?,
        duration: Long,
        description: String?,
        seriesName: String?,
        seriesNumber: String?,
        publisher: String?,
        publishedDate: String?,
        isbn13: String?,
        language: String?,
        pageCount: Int?,
        categoriesJson: String,
        nowMs: Long,
    )

    @Query("""
        UPDATE book_cache
        SET isFinished = :finished,
            serverReadStatus = CASE
                WHEN :finished THEN 'READ'
                WHEN serverReadStatus IN ('READ', 'COMPLETED', 'FINISHED') THEN NULL
                ELSE serverReadStatus
            END,
            readProgress = CASE WHEN :finished THEN 1.0 ELSE readProgress END,
            epubProgress = CASE WHEN :finished AND epubProgress IS NOT NULL THEN 1.0 ELSE epubProgress END,
            inProgress = CASE WHEN :finished THEN 0 ELSE inProgress END,
            lastReadTime = :nowMs
        WHERE id = :bookId AND (connectionId = :connectionId OR (:connectionId IS NULL AND connectionId IS NULL))
    """)
    suspend fun updateFinishedStatus(bookId: String, connectionId: String?, finished: Boolean, nowMs: Long)

    @Query("""
        UPDATE book_cache
        SET isFinished = :finished,
            serverReadStatus = CASE
                WHEN :finished THEN 'READ'
                WHEN serverReadStatus IN ('READ', 'COMPLETED', 'FINISHED') THEN NULL
                ELSE serverReadStatus
            END,
            readProgress = CASE WHEN :finished THEN 1.0 ELSE readProgress END,
            epubProgress = CASE WHEN :finished AND epubProgress IS NOT NULL THEN 1.0 ELSE epubProgress END,
            inProgress = CASE WHEN :finished THEN 0 ELSE inProgress END,
            lastReadTime = :nowMs
        WHERE id = :bookId
    """)
    suspend fun updateFinishedStatusById(bookId: String, finished: Boolean, nowMs: Long)

    @Query("""
        UPDATE book_cache
        SET personalRating = :rating,
            cachedAt = :nowMs
        WHERE id = :bookId AND (connectionId = :connectionId OR (:connectionId IS NULL AND connectionId IS NULL))
    """)
    suspend fun updatePersonalRating(
        bookId: String,
        connectionId: String?,
        rating: Float,
        nowMs: Long,
    )

    @Query("""
        UPDATE book_cache
        SET personalRating = :rating,
            serverReadStatus = COALESCE(:serverReadStatus, serverReadStatus),
            isFinished = CASE
                WHEN :serverReadStatus IN ('READ', 'SKIMMED') THEN 1
                WHEN :serverReadStatus IS NOT NULL THEN 0
                ELSE isFinished
            END,
            hideFromContinue = CASE
                WHEN :serverReadStatus = 'ABANDONED' THEN 1
                WHEN :serverReadStatus IS NOT NULL THEN 0
                ELSE hideFromContinue
            END,
            readProgress = CASE
                WHEN :serverReadStatus IN ('READ', 'SKIMMED') THEN 1.0
                WHEN :serverReadStatus = 'UNREAD' THEN 0.0
                ELSE readProgress
            END,
            epubProgress = CASE
                WHEN :serverReadStatus IN ('READ', 'SKIMMED') AND epubProgress IS NOT NULL THEN 1.0
                WHEN :serverReadStatus = 'UNREAD' AND epubProgress IS NOT NULL THEN 0.0
                ELSE epubProgress
            END,
            inProgress = CASE
                WHEN :serverReadStatus IN ('READING', 'REREADING', 'ON_HOLD') THEN 1
                WHEN :serverReadStatus IS NOT NULL THEN 0
                ELSE inProgress
            END,
            cachedAt = :nowMs
        WHERE id = :bookId AND connectionId = :connectionId
    """)
    suspend fun updateBookOrbitUserData(
        bookId: String,
        connectionId: String,
        rating: Float?,
        serverReadStatus: String?,
        nowMs: Long,
    )

    @Query("""
        UPDATE book_cache
        SET isFinished = :finished,
            hideFromContinue = :hideFromContinue,
            serverReadStatus = :serverReadStatus,
            readProgress = CASE WHEN :finished THEN 1.0 ELSE readProgress END,
            epubProgress = CASE WHEN :finished AND epubProgress IS NOT NULL THEN 1.0 ELSE epubProgress END,
            inProgress = CASE
                WHEN :finished OR :hideFromContinue THEN 0
                WHEN source = 'GRIMMORY' AND :serverReadStatus NOT IN ('READING', 'RE_READING') THEN 0
                WHEN readProgress > 0.001 AND readProgress < 0.99 THEN 1
                WHEN epubProgress IS NOT NULL AND epubProgress > 0.001 AND epubProgress < 0.99 THEN 1
                WHEN currentTime > 0 THEN 1
                ELSE 0
            END,
            lastReadTime = :nowMs
        WHERE id = :bookId AND (connectionId = :connectionId OR (:connectionId IS NULL AND connectionId IS NULL))
    """)
    suspend fun updateReadState(
        bookId: String,
        connectionId: String?,
        finished: Boolean,
        hideFromContinue: Boolean,
        serverReadStatus: String,
        nowMs: Long,
    )

    @Query("""
        UPDATE book_cache
        SET readProgress = :progress,
            epubProgress = :progress,
            isFinished = CASE
                WHEN serverReadStatus IN ('READ', 'COMPLETED', 'FINISHED') THEN 1
                WHEN :progress >= 0.99 THEN 1
                ELSE 0
            END,
            currentTime = CASE
                WHEN :currentTimeSec >= 0 THEN :currentTimeSec
                ELSE currentTime
            END,
            epubLocator = COALESCE(:locatorJson, epubLocator),
            lastReadTime = :nowMs,
            inProgress = CASE
                WHEN hideFromContinue = 0
                    AND (source != 'GRIMMORY' OR serverReadStatus IS NULL OR serverReadStatus IN ('READING', 'RE_READING'))
                    AND :progress < 0.99
                    AND (:progress > 0.001 OR :currentTimeSec > 0)
                THEN 1
                ELSE 0
            END
        WHERE id = :bookId AND (connectionId = :connectionId OR (:connectionId IS NULL AND connectionId IS NULL))
    """)
    suspend fun updateUnifiedProgress(
        bookId: String,
        connectionId: String?,
        progress: Float,
        currentTimeSec: Long,
        locatorJson: String?,
        nowMs: Long,
    ): Int

    @Query("""
        UPDATE book_cache
        SET readProgress = :progress,
            epubProgress = :progress,
            isFinished = CASE
                WHEN serverReadStatus IN ('READ', 'COMPLETED', 'FINISHED') THEN 1
                WHEN :progress >= 0.99 THEN 1
                ELSE 0
            END,
            currentTime = CASE
                WHEN :currentTimeSec >= 0 THEN :currentTimeSec
                ELSE currentTime
            END,
            epubLocator = COALESCE(:locatorJson, epubLocator),
            lastReadTime = :nowMs,
            inProgress = CASE
                WHEN hideFromContinue = 0
                    AND (source != 'GRIMMORY' OR serverReadStatus IS NULL OR serverReadStatus IN ('READING', 'RE_READING'))
                    AND :progress < 0.99
                    AND (:progress > 0.001 OR :currentTimeSec > 0)
                THEN 1
                ELSE 0
            END
        WHERE id = :bookId
    """)
    suspend fun updateUnifiedProgressById(
        bookId: String,
        progress: Float,
        currentTimeSec: Long,
        locatorJson: String?,
        nowMs: Long,
    )

    @Query("""
        UPDATE book_cache
        SET isDownloaded = :downloaded,
            cachedAt = :nowMs
        WHERE id = :bookId AND (connectionId = :connectionId OR (:connectionId IS NULL AND connectionId IS NULL))
    """)
    suspend fun updateDownloadedStatus(
        bookId: String,
        connectionId: String?,
        downloaded: Boolean,
        nowMs: Long,
    ): Int

    @Query("""
        UPDATE book_cache
        SET isDownloaded = :downloaded,
            cachedAt = :nowMs
        WHERE id = :bookId
    """)
    suspend fun updateDownloadedStatusById(bookId: String, downloaded: Boolean, nowMs: Long)

    @Query("""
        SELECT id, connectionId, source FROM book_cache
        WHERE mediaType = 'AUDIOBOOK' AND narratorEnrichedAt = 0
        LIMIT :limit
    """)
    suspend fun audiobooksNeedingNarratorEnrichment(limit: Int = 1000): List<BookCacheIdentity>

    @Query("SELECT COUNT(*) FROM book_cache WHERE mediaType = 'AUDIOBOOK' AND narratorEnrichedAt = 0")
    suspend fun countAudiobooksNeedingNarratorEnrichment(): Int

    @Query("""
        UPDATE book_cache
        SET narrator = :narrator,
            narratorEnrichedAt = :nowMs
        WHERE id = :bookId AND (connectionId = :connectionId OR (:connectionId IS NULL AND connectionId IS NULL))
    """)
    suspend fun setNarrator(bookId: String, connectionId: String?, narrator: String?, nowMs: Long)

    @Query("DELETE FROM book_cache WHERE connectionId = :connectionId")
    suspend fun deleteByConnection(connectionId: String)

    @Query("""
        DELETE FROM book_cache
        WHERE connectionId = :connectionId
          AND libraryId = :libraryId
          AND cachedAt < :refreshedAt
    """)
    suspend fun deleteStaleForConnectionLibrary(connectionId: String, libraryId: String, refreshedAt: Long)

    @Query("DELETE FROM book_cache WHERE source = :source AND connectionId IS NULL")
    suspend fun deleteBySource(source: String)

    @Query("DELETE FROM book_cache WHERE cacheKey IN (:bookKeys)")
    suspend fun deleteByCacheKeys(bookKeys: List<String>)

    @Query("DELETE FROM book_cache")
    suspend fun clearAll()

    @Query("SELECT COUNT(*) FROM book_cache")
    suspend fun count(): Int

    @Query("SELECT COUNT(*) FROM book_cache WHERE connectionId = :connectionId")
    suspend fun countForConnection(connectionId: String): Int

    @Query("SELECT DISTINCT connectionId FROM book_cache WHERE connectionId IS NOT NULL")
    suspend fun getConnectionIds(): List<String>

    @Query("SELECT MAX(cachedAt) FROM book_cache")
    suspend fun newestCacheWrite(): Long?

    @Query("SELECT COUNT(*) FROM book_cache WHERE inProgress = 1 AND lastReadTime = 0")
    suspend fun countInProgressMissingTouchTime(): Int

    @Query("""
        SELECT source || ':' || CASE WHEN id != '' THEN id ELSE title END
        FROM book_cache
        WHERE isFinished = 1
           OR hideFromContinue = 1
           OR readProgress >= 0.99
           OR COALESCE(epubProgress, 0) >= 0.99
           OR (source = 'GRIMMORY' AND serverReadStatus IS NOT NULL AND serverReadStatus NOT IN ('READING', 'RE_READING'))
    """)
    fun observeSuppressedContinueIdentities(): Flow<List<String>>

    @Query("""
        SELECT * FROM book_cache
        WHERE inProgress = 1 AND isFinished = 0 AND hideFromContinue = 0
          AND (source != 'GRIMMORY' OR serverReadStatus IS NULL OR serverReadStatus IN ('READING', 'RE_READING'))
        ORDER BY lastReadTime DESC, addedOn DESC
        LIMIT :limit
    """)
    suspend fun getInProgressOnce(limit: Int = 50): List<CachedBook>

    @Query("""
        SELECT * FROM book_cache
        ORDER BY addedOn DESC
        LIMIT :limit OFFSET :offset
    """)
    suspend fun getRecentlyAdded(limit: Int = 40, offset: Int = 0): List<CachedBook>

    @Query("""
        SELECT * FROM book_cache
        WHERE mediaType IN ('EBOOK', 'AUDIOBOOK')
        ORDER BY addedOn DESC
        LIMIT :limit
    """)
    suspend fun getBooksForLinking(limit: Int = 20000): List<CachedBook>

    @Query("""
        SELECT * FROM book_cache
        WHERE isDownloaded = 1
        ORDER BY lastReadTime DESC, addedOn DESC
        LIMIT :limit
    """)
    suspend fun getDownloaded(limit: Int = 40): List<CachedBook>

    @Query("""
        SELECT * FROM book_cache
        WHERE inProgress = 1 AND isFinished = 0 AND hideFromContinue = 0
          AND (source != 'GRIMMORY' OR serverReadStatus IS NULL OR serverReadStatus IN ('READING', 'RE_READING'))
        ORDER BY lastReadTime DESC, addedOn DESC
        LIMIT :limit
    """)
    fun observeInProgress(limit: Int = 50): Flow<List<CachedBook>>

    @Query("""
        SELECT * FROM book_cache
        WHERE inProgress = 1 AND isFinished = 0 AND hideFromContinue = 0
          AND (source != 'GRIMMORY' OR serverReadStatus IS NULL OR serverReadStatus IN ('READING', 'RE_READING'))
          AND (libraryId IS NULL OR libraryId NOT IN (:excludedLibraryIds))
        ORDER BY lastReadTime DESC, addedOn DESC
        LIMIT :limit
    """)
    fun observeInProgressExcludingLibraries(
        excludedLibraryIds: List<String>,
        limit: Int = 500,
    ): Flow<List<CachedBook>>

    @Query("""
        SELECT * FROM book_cache
        ORDER BY addedOn DESC
        LIMIT :limit
    """)
    fun observeRecentlyAdded(limit: Int = 40): Flow<List<CachedBook>>

    @Query("""
        SELECT * FROM book_cache
        WHERE libraryId IS NULL OR libraryId NOT IN (:excludedLibraryIds)
        ORDER BY addedOn DESC
        LIMIT :limit
    """)
    fun observeRecentlyAddedExcludingLibraries(
        excludedLibraryIds: List<String>,
        limit: Int = 40,
    ): Flow<List<CachedBook>>

    @Query("""
        SELECT * FROM book_cache
        WHERE isDownloaded = 1
        ORDER BY lastReadTime DESC, addedOn DESC
        LIMIT :limit
    """)
    fun observeDownloaded(limit: Int = 40): Flow<List<CachedBook>>

    @Query("""
        SELECT * FROM book_cache
        WHERE isDownloaded = 1
          AND (libraryId IS NULL OR libraryId NOT IN (:excludedLibraryIds))
        ORDER BY lastReadTime DESC, addedOn DESC
        LIMIT :limit
    """)
    fun observeDownloadedExcludingLibraries(
        excludedLibraryIds: List<String>,
        limit: Int = 40,
    ): Flow<List<CachedBook>>

    @Query("SELECT COUNT(*) FROM book_cache")
    fun observeCount(): Flow<Int>

    @Query("SELECT COUNT(*) FROM book_cache WHERE libraryId IS NULL OR libraryId NOT IN (:excludedLibraryIds)")
    fun observeCountExcludingLibraries(excludedLibraryIds: List<String>): Flow<Int>

    @Query("""
        SELECT * FROM book_cache
        ORDER BY addedOn DESC
        LIMIT :limit
    """)
    fun observeAll(limit: Int = 20000): Flow<List<CachedBook>>

    @Query("""
        SELECT cacheKey, id, connectionId, source, mediaType, title, subtitle,
               author, narrator, coverUrl, duration, currentTime, isFinished,
               readProgress, epubProgress, lastReadTime, addedOn, libraryId,
               libraryName, seriesName, seriesNumber, publisher, publishedDate,
               language, pageCount, isbn13, personalRating, goodreadsRating,
               primaryFileType, isDownloaded, hideFromContinue,
               readAlongAvailable, hasAudio, hasEbook, inProgress, serverReadStatus
        FROM book_cache
        ORDER BY addedOn DESC
        LIMIT :limit
    """)
    fun observeAllForList(limit: Int = 20000): Flow<List<CachedBookListItem>>

    @Query("""
        SELECT cacheKey, id, connectionId, source, mediaType, title, subtitle,
               author, narrator, coverUrl, duration, currentTime, isFinished,
               readProgress, epubProgress, lastReadTime, addedOn, libraryId,
               libraryName, seriesName, seriesNumber, publisher, publishedDate,
               language, pageCount, isbn13, personalRating, goodreadsRating,
               primaryFileType, isDownloaded, hideFromContinue,
               readAlongAvailable, hasAudio, hasEbook, inProgress, serverReadStatus
        FROM book_cache
        WHERE libraryId IS NULL OR libraryId NOT IN (:excludedLibraryIds)
        ORDER BY addedOn DESC
        LIMIT :limit
    """)
    fun observeAllForListExcludingLibraries(
        excludedLibraryIds: List<String>,
        limit: Int = 20000,
    ): Flow<List<CachedBookListItem>>

    @Query("""
        SELECT seriesName AS name, COUNT(*) AS count
        FROM book_cache
        WHERE seriesName IS NOT NULL AND seriesName != ''
        GROUP BY seriesName
        ORDER BY seriesName COLLATE NOCASE
    """)
    suspend fun groupBySeries(): List<BrowseGroupRow>

    @Query("""
        SELECT author AS name, COUNT(*) AS count
        FROM book_cache
        WHERE author IS NOT NULL AND author != ''
        GROUP BY author
        ORDER BY author COLLATE NOCASE
    """)
    suspend fun groupByAuthor(): List<BrowseGroupRow>

    @Query("""
        SELECT narrator AS name, COUNT(*) AS count
        FROM book_cache
        WHERE narrator IS NOT NULL AND narrator != ''
        GROUP BY narrator
        ORDER BY narrator COLLATE NOCASE
    """)
    suspend fun groupByNarrator(): List<BrowseGroupRow>

    @Query("""
        SELECT categoriesJson FROM book_cache
        WHERE categoriesJson IS NOT NULL AND categoriesJson != '[]' AND categoriesJson != ''
    """)
    suspend fun allCategoriesJson(): List<String>

    @Query("""
        SELECT coverUrl FROM book_cache
        WHERE seriesName = :seriesName AND coverUrl IS NOT NULL
        ORDER BY CAST(seriesNumber AS REAL) ASC, addedOn DESC
        LIMIT 1
    """)
    suspend fun firstCoverForSeries(seriesName: String): String?

    @Query("""
        SELECT coverUrl FROM book_cache
        WHERE author = :authorName AND coverUrl IS NOT NULL
        ORDER BY addedOn DESC
        LIMIT 1
    """)
    suspend fun firstCoverForAuthor(authorName: String): String?

    @Query("""
        SELECT * FROM book_cache
        WHERE seriesName = :seriesName
        ORDER BY CAST(seriesNumber AS REAL) ASC, addedOn DESC
        LIMIT :limit
    """)
    suspend fun booksWhereSeries(seriesName: String, limit: Int = 1000): List<CachedBook>

    @Query("""
        SELECT * FROM book_cache
        WHERE TRIM(seriesName) COLLATE NOCASE = :seriesName
          AND source = :source
          AND mediaType = 'AUDIOBOOK'
          AND (connectionId = :connectionId OR (connectionId IS NULL AND :connectionId IS NULL))
          AND (libraryId = :libraryId OR (libraryId IS NULL AND :libraryId IS NULL))
        ORDER BY CAST(seriesNumber AS REAL) ASC, title COLLATE NOCASE ASC
        LIMIT :limit
    """)
    suspend fun audiobooksInSeries(
        seriesName: String,
        source: String,
        connectionId: String?,
        libraryId: String?,
        limit: Int = 1000,
    ): List<CachedBook>

    @Query("""
        SELECT * FROM book_cache
        WHERE author LIKE :authorMatch
        ORDER BY addedOn DESC
        LIMIT :limit
    """)
    suspend fun booksWhereAuthorLike(authorMatch: String, limit: Int = 1000): List<CachedBook>

    @Query("""
        SELECT * FROM book_cache
        WHERE narrator LIKE :narratorMatch
        ORDER BY addedOn DESC
        LIMIT :limit
    """)
    suspend fun booksWhereNarratorLike(narratorMatch: String, limit: Int = 1000): List<CachedBook>

    @Query("""
        SELECT * FROM book_cache
        WHERE categoriesJson LIKE :tagMatch
        ORDER BY addedOn DESC
        LIMIT :limit
    """)
    suspend fun booksWhereTagLike(tagMatch: String, limit: Int = 1000): List<CachedBook>

    @Query("""
        SELECT * FROM book_cache
        WHERE mediaType = 'AUDIOBOOK'
          AND (title LIKE '%' || :query || '%'
            OR author LIKE '%' || :query || '%'
            OR narrator LIKE '%' || :query || '%')
        ORDER BY lastReadTime DESC, addedOn DESC
        LIMIT 1000
    """)
    suspend fun searchAudiobooksByMetadata(query: String): List<CachedBook>

    @Query("""
        SELECT * FROM book_cache
        WHERE mediaType = 'AUDIOBOOK'
          AND isFinished = 0 AND hideFromContinue = 0
          AND (source != 'GRIMMORY' OR serverReadStatus IS NULL OR serverReadStatus IN ('READING', 'RE_READING'))
          AND (currentTime > 0 OR readProgress > 0.001)
        ORDER BY lastReadTime DESC, addedOn DESC
        LIMIT :limit
    """)
    suspend fun getInProgressAudiobooksOnce(limit: Int): List<CachedBook>

    @Query("""
        SELECT * FROM book_cache
        WHERE mediaType = 'AUDIOBOOK'
        ORDER BY addedOn DESC
        LIMIT :limit
    """)
    suspend fun getRecentlyAddedAudiobooks(limit: Int): List<CachedBook>
}

data class BrowseGroupRow(val name: String, val count: Int)

data class BookCacheIdentity(
    val id: String,
    val connectionId: String?,
    val source: String,
)

data class CachedBookListItem(
    val cacheKey: String,
    val id: String,
    val connectionId: String?,
    val source: String,
    val mediaType: String,
    val title: String,
    val subtitle: String?,
    val author: String?,
    val narrator: String?,
    val coverUrl: String?,
    val duration: Long,
    val currentTime: Long,
    val isFinished: Boolean,
    val readProgress: Float,
    val epubProgress: Float?,
    val lastReadTime: Long,
    val addedOn: Long,
    val libraryId: String?,
    val libraryName: String?,
    val seriesName: String?,
    val seriesNumber: String?,
    val publisher: String?,
    val publishedDate: String?,
    val language: String?,
    val pageCount: Int?,
    val isbn13: String?,
    val personalRating: Float?,
    val goodreadsRating: Float?,
    val primaryFileType: String?,
    val isDownloaded: Boolean,
    val hideFromContinue: Boolean,
    val readAlongAvailable: Boolean,
    val hasAudio: Boolean,
    val hasEbook: Boolean,
    val inProgress: Boolean,
    val serverReadStatus: String?,
)

private val cacheJson = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }

fun CachedBook.toBook(): Book {
    val categories = runCatching {
        cacheJson.decodeFromString<List<String>>(categoriesJson)
    }.getOrDefault(emptyList())
    val normalizedStatus = serverReadStatus?.uppercase()
    val statusFinished = normalizedStatus in terminalServerReadStatuses
    return Book(
        id = id,
        title = title,
        subtitle = subtitle,
        author = author,
        narrator = narrator,
        description = description,
        coverUrl = coverUrl,
        duration = duration,
        currentTime = currentTime,
        isFinished = isFinished || statusFinished,
        source = runCatching { BookSource.valueOf(source) }.getOrDefault(BookSource.GRIMMORY),
        mediaType = runCatching { AppMediaType.valueOf(mediaType) }.getOrDefault(AppMediaType.AUDIOBOOK),
        readStatus = when {
            statusFinished || isFinished -> ReadStatus.COMPLETED
            normalizedStatus in activeServerReadStatuses -> ReadStatus.IN_PROGRESS
            normalizedStatus == "PAUSED" || normalizedStatus == "ON_HOLD" -> ReadStatus.ON_HOLD
            inProgress -> ReadStatus.IN_PROGRESS
            else -> ReadStatus.UNREAD
        },
        seriesName = seriesName,
        seriesNumber = seriesNumber,
        publisher = publisher,
        publishedDate = publishedDate,
        isbn13 = isbn13,
        language = language,
        pageCount = pageCount,
        categories = categories,
        personalRating = personalRating,
        goodreadsRating = goodreadsRating,
        primaryFileType = primaryFileType,
        libraryId = libraryId,
        libraryName = libraryName,
        connectionId = connectionId,
        addedOn = addedOn,
        lastReadTime = lastReadTime,
        readProgress = readProgress,
        epubProgress = epubProgress,
        epubLocator = epubLocator,
        readAlongAvailable = readAlongAvailable,
        hasAudio = hasAudio || mediaType == "AUDIOBOOK" || readAlongAvailable,
        hasEbook = hasEbook || mediaType == "EBOOK" || readAlongAvailable,
        hideFromContinue = hideFromContinue,
        serverReadStatus = normalizedStatus,
        isDownloaded = isDownloaded,
    )
}

fun CachedBookListItem.toBook(): Book {
    val normalizedStatus = serverReadStatus?.uppercase()
    val statusFinished = normalizedStatus in terminalServerReadStatuses
    return Book(
        id = id,
        title = title,
        subtitle = subtitle,
        author = author,
        narrator = narrator,
        description = null,
        coverUrl = coverUrl,
        duration = duration,
        currentTime = currentTime,
        isFinished = isFinished || statusFinished,
        source = runCatching { BookSource.valueOf(source) }.getOrDefault(BookSource.GRIMMORY),
        mediaType = runCatching { AppMediaType.valueOf(mediaType) }.getOrDefault(AppMediaType.AUDIOBOOK),
        readStatus = when {
            statusFinished || isFinished -> ReadStatus.COMPLETED
            normalizedStatus in activeServerReadStatuses -> ReadStatus.IN_PROGRESS
            normalizedStatus == "PAUSED" || normalizedStatus == "ON_HOLD" -> ReadStatus.ON_HOLD
            inProgress -> ReadStatus.IN_PROGRESS
            else -> ReadStatus.UNREAD
        },
        seriesName = seriesName,
        seriesNumber = seriesNumber,
        publisher = publisher,
        publishedDate = publishedDate,
        isbn13 = isbn13,
        language = language,
        pageCount = pageCount,
        categories = emptyList(),
        personalRating = personalRating,
        goodreadsRating = goodreadsRating,
        primaryFileType = primaryFileType,
        libraryId = libraryId,
        libraryName = libraryName,
        connectionId = connectionId,
        addedOn = addedOn,
        lastReadTime = lastReadTime,
        readProgress = readProgress,
        epubProgress = epubProgress,
        epubLocator = null,
        readAlongAvailable = readAlongAvailable,
        hasAudio = hasAudio || mediaType == "AUDIOBOOK" || readAlongAvailable,
        hasEbook = hasEbook || mediaType == "EBOOK" || readAlongAvailable,
        hideFromContinue = hideFromContinue,
        serverReadStatus = normalizedStatus,
        isDownloaded = isDownloaded,
    )
}

fun Book.toCachedBook(nowMs: Long = System.currentTimeMillis()): CachedBook {
    val key = "${connectionId ?: source.name}:$id"
    val normalizedStatus = serverReadStatus?.uppercase()
    val statusFinished = normalizedStatus in terminalServerReadStatuses
    val statusAllowsContinue = source != BookSource.GRIMMORY || normalizedStatus == null || normalizedStatus in activeServerReadStatuses
    val audioProgress = if (duration > 0 && currentTime > 0) currentTime.toFloat() / duration else readProgress
    val epubProg = epubProgress ?: 0f
    val inProg = !isFinished && !statusFinished && !hideFromContinue && statusAllowsContinue && (
        audioProgress in 0.01f..0.99f ||
        epubProg in 0.01f..0.99f ||
        currentTime > 0L
    )
    val effectiveLastReadTime = lastReadTime.takeIf { it > 0L } ?: if (inProg) nowMs else 0L
    val cats = runCatching {
        cacheJson.encodeToString(
            kotlinx.serialization.serializer<List<String>>(),
            categories,
        )
    }.getOrDefault("[]")
    return CachedBook(
        cacheKey = key,
        id = id,
        connectionId = connectionId,
        source = source.name,
        mediaType = mediaType.name,
        title = title,
        author = author,
        narrator = narrator,
        coverUrl = coverUrl,
        duration = duration,
        currentTime = currentTime,
        isFinished = isFinished || statusFinished,
        readProgress = readProgress,
        epubProgress = epubProgress,
        epubLocator = epubLocator,
        lastReadTime = effectiveLastReadTime,
        addedOn = addedOn,
        libraryId = libraryId,
        libraryName = libraryName,
        seriesName = seriesName,
        seriesNumber = seriesNumber,
        publisher = publisher,
        publishedDate = publishedDate,
        description = description,
        language = language,
        pageCount = pageCount,
        isDownloaded = isDownloaded,
        hideFromContinue = hideFromContinue,
        readAlongAvailable = readAlongAvailable,
        hasAudio = hasAudio,
        hasEbook = hasEbook,
        categoriesJson = cats,
        subtitle = subtitle,
        isbn13 = isbn13,
        personalRating = personalRating,
        goodreadsRating = goodreadsRating,
        primaryFileType = primaryFileType,
        inProgress = inProg,
        cachedAt = nowMs,
        serverReadStatus = normalizedStatus,
    )
}

private val activeServerReadStatuses = setOf("READING", "RE_READING")
private val terminalServerReadStatuses = setOf("READ", "COMPLETED", "FINISHED")
