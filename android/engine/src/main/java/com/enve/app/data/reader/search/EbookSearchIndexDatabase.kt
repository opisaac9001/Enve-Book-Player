package com.enve.app.data.reader.search

import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Fts4
import androidx.room.FtsOptions
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RoomDatabase

const val META_FINGERPRINT = "fingerprint"
const val META_COMPLETE = "complete"
const val META_TRUE = "1"

@Entity(tableName = "search_meta")
data class SearchMetaEntity(
    @PrimaryKey val metaKey: String,
    val metaValue: String,
)

@Entity(tableName = "search_sections")
data class SearchSectionEntity(
    @PrimaryKey val sectionIndex: Int,
    val textLength: Int,
)

@Entity(
    tableName = "search_chunks",
    indices = [Index(value = ["sectionIndex", "chunkIndex"], unique = true)],
)
data class SearchChunkEntity(
    @PrimaryKey(autoGenerate = true) val chunkId: Long = 0,
    val sectionIndex: Int,
    val chunkIndex: Int,
    val startOffset: Int,
    val endOffset: Int,
    val ownedEnd: Int,
    val text: String,
    val folded: String,
)

@Entity(tableName = "search_chunks_fts")
@Fts4(contentEntity = SearchChunkEntity::class, tokenizer = FtsOptions.TOKENIZER_UNICODE61)
data class SearchChunkFtsEntity(
    val folded: String,
)

@Entity(
    tableName = "search_headings",
    indices = [Index(value = ["normalized"]), Index(value = ["sectionIndex", "startOffset"])],
)
data class SearchHeadingEntity(
    @PrimaryKey(autoGenerate = true) val headingId: Long = 0,
    val sectionIndex: Int,
    val startOffset: Int,
    val endOffset: Int,
    val normalized: String,
)

data class SearchChunkScan(
    val chunkId: Long,
    val sectionIndex: Int,
    val chunkIndex: Int,
    val startOffset: Int,
    val folded: String,
    val text: String,
    val endOffset: Int,
    val ownedEnd: Int,
)

data class SearchChunkText(
    val startOffset: Int,
    val endOffset: Int,
    val text: String,
)

data class SearchHeadingRange(
    val sectionIndex: Int,
    val startOffset: Int,
    val endOffset: Int,
)

@Dao
interface EbookSearchIndexDao {

    @Query("SELECT metaValue FROM search_meta WHERE metaKey = :key")
    suspend fun meta(key: String): String?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun putMeta(entity: SearchMetaEntity)

    @Query("SELECT COUNT(*) FROM search_sections")
    suspend fun sectionCount(): Int

    @Query("SELECT sectionIndex FROM search_sections")
    suspend fun indexedSections(): List<Int>

    @Query("SELECT textLength FROM search_sections WHERE sectionIndex = :sectionIndex")
    suspend fun sectionLength(sectionIndex: Int): Int?

    @Insert
    suspend fun insertSection(entity: SearchSectionEntity)

    @Insert
    suspend fun insertChunks(entities: List<SearchChunkEntity>)

    @Insert
    suspend fun insertHeadings(entities: List<SearchHeadingEntity>)

    @Query(
        """
        SELECT sectionIndex, startOffset, endOffset FROM search_headings
        WHERE normalized = :normalized AND sectionIndex <= :maxSection
        ORDER BY sectionIndex, startOffset
        LIMIT :limit
        """,
    )
    suspend fun headingMatches(normalized: String, maxSection: Int, limit: Int): List<SearchHeadingRange>

    @Query(
        """
        SELECT chunkId, sectionIndex, chunkIndex, startOffset, folded, text, endOffset, ownedEnd FROM search_chunks
        WHERE sectionIndex <= :maxSection
          AND (sectionIndex > :cursorSection OR (sectionIndex = :cursorSection AND chunkIndex > :cursorChunk))
        ORDER BY sectionIndex, chunkIndex
        LIMIT :limit
        """,
    )
    suspend fun chunksAfter(
        cursorSection: Int,
        cursorChunk: Int,
        maxSection: Int,
        limit: Int,
    ): List<SearchChunkScan>

    @Query(
        """
        SELECT chunkId, sectionIndex, chunkIndex, startOffset, folded, text, endOffset, ownedEnd FROM search_chunks
        WHERE sectionIndex <= :maxSection
          AND (sectionIndex > :cursorSection OR (sectionIndex = :cursorSection AND chunkIndex > :cursorChunk))
          AND chunkId IN (SELECT rowid FROM search_chunks_fts WHERE search_chunks_fts MATCH :match)
        ORDER BY sectionIndex, chunkIndex
        LIMIT :limit
        """,
    )
    suspend fun matchedChunksAfter(
        match: String,
        cursorSection: Int,
        cursorChunk: Int,
        maxSection: Int,
        limit: Int,
    ): List<SearchChunkScan>

    @Query(
        """
        SELECT startOffset, endOffset, text FROM search_chunks
        WHERE sectionIndex = :sectionIndex AND startOffset < :end AND endOffset > :start
        ORDER BY startOffset
        """,
    )
    suspend fun chunkText(sectionIndex: Int, start: Int, end: Int): List<SearchChunkText>
}

@Database(
    entities = [
        SearchMetaEntity::class,
        SearchSectionEntity::class,
        SearchChunkEntity::class,
        SearchChunkFtsEntity::class,
        SearchHeadingEntity::class,
    ],
    version = 2,
    exportSchema = false,
)
abstract class EbookSearchIndexDatabase : RoomDatabase() {
    abstract fun searchDao(): EbookSearchIndexDao
}
