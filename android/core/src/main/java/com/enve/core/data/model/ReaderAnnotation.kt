package com.enve.core.data.model

import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

enum class AnnotationKind {
    HIGHLIGHT, NOTE, BOOKMARK;

    val label: String get() = when (this) {
        HIGHLIGHT -> "Highlight"
        NOTE      -> "Note"
        BOOKMARK  -> "Bookmark"
    }

    companion object {
        fun parse(name: String?): AnnotationKind = name?.let {
            runCatching { valueOf(it) }.getOrNull()
        } ?: HIGHLIGHT
    }
}

enum class AnnotationStyle {
    HIGHLIGHT, UNDERLINE, STRIKETHROUGH, SQUIGGLY, NONE;

    val label: String get() = when (this) {
        HIGHLIGHT     -> "Highlight"
        UNDERLINE     -> "Underline"
        STRIKETHROUGH -> "Strike"
        SQUIGGLY      -> "Squiggle"
        NONE          -> "-"
    }

    companion object {
        fun parse(name: String?): AnnotationStyle = name?.let {
            runCatching { valueOf(it) }.getOrNull()
        } ?: HIGHLIGHT
    }
}

enum class AnnotationMedia {
    EPUB, PDF, CBZ, AUDIOBOOK;

    companion object {
        fun parse(name: String?): AnnotationMedia = name?.let {
            runCatching { valueOf(it) }.getOrNull()
        } ?: EPUB
    }
}

@Entity(
    tableName = "reader_annotations",
    indices = [
        Index("bookId"),
        Index("kind"),
        Index("updatedAt"),
        Index("deletedAt"),
        Index("serverId"),
    ],
)
data class ReaderAnnotation(
    @PrimaryKey val id:           String,
    @ColumnInfo val bookId:       String,

    @ColumnInfo val kind:         String = AnnotationKind.HIGHLIGHT.name,
    @ColumnInfo val media:        String = AnnotationMedia.EPUB.name,
    @ColumnInfo val style:        String = AnnotationStyle.HIGHLIGHT.name,
    @ColumnInfo val colorHex:     String = "#FFF59D",

    @ColumnInfo val locatorJson:  String? = null,
    @ColumnInfo val pdfPage:      Int?    = null,
    @ColumnInfo val pdfRectsJson: String? = null,
    @ColumnInfo val cbzPage:      Int?    = null,
    @ColumnInfo val audioPositionMs: Long? = null,
    @ColumnInfo val chapterId:    String? = null,

    @ColumnInfo val cfi:                 String? = null,
    @ColumnInfo val cssSelector:         String? = null,
    @ColumnInfo val textQuoteExact:      String? = null,
    @ColumnInfo val textQuotePrefix:     String? = null,
    @ColumnInfo val textQuoteSuffix:     String? = null,
    @ColumnInfo val progression:         Double? = null,
    @ColumnInfo val totalProgression:    Double? = null,

    @ColumnInfo val selectedText: String  = "",
    @ColumnInfo val note:         String  = "",
    @ColumnInfo val tagsJson: String = "[]",

    @ColumnInfo val attachmentUriString: String? = null,
    @ColumnInfo val attachmentKind:      String? = null,

    @ColumnInfo val createdAt:    Long    = System.currentTimeMillis(),
    @ColumnInfo val updatedAt:    Long    = System.currentTimeMillis(),
    @ColumnInfo val deletedAt:    Long?   = null,
    @ColumnInfo val serverId:     String? = null,
    @ColumnInfo val providerSource: String = "local",
    @ColumnInfo val syncDirty:    Boolean = true,
    @ColumnInfo val syncEtag:     String? = null,
)

@Dao
interface ReaderAnnotationDao {

    @Query("SELECT * FROM reader_annotations WHERE bookId = :bookId AND deletedAt IS NULL ORDER BY createdAt DESC")
    fun flowByBook(bookId: String): Flow<List<ReaderAnnotation>>

    @Query("SELECT * FROM reader_annotations WHERE bookId = :bookId AND kind = :kind AND deletedAt IS NULL ORDER BY createdAt ASC")
    fun flowByBookAndKind(bookId: String, kind: String): Flow<List<ReaderAnnotation>>

    @Query("SELECT * FROM reader_annotations WHERE deletedAt IS NULL ORDER BY updatedAt DESC")
    fun flowAll(): Flow<List<ReaderAnnotation>>

    @Query("""
        SELECT * FROM reader_annotations
        WHERE deletedAt IS NULL
          AND (selectedText LIKE :pattern OR note LIKE :pattern OR tagsJson LIKE :pattern)
        ORDER BY updatedAt DESC
    """)
    fun search(pattern: String): Flow<List<ReaderAnnotation>>

    @Query("SELECT * FROM reader_annotations WHERE bookId = :bookId AND deletedAt IS NULL ORDER BY createdAt DESC")
    suspend fun getByBook(bookId: String): List<ReaderAnnotation>

    @Query("SELECT * FROM reader_annotations WHERE id = :id LIMIT 1")
    suspend fun getById(id: String): ReaderAnnotation?

    @Query("SELECT * FROM reader_annotations WHERE serverId = :serverId AND providerSource = :providerSource LIMIT 1")
    suspend fun getByServerId(serverId: String, providerSource: String): ReaderAnnotation?

    @Query("SELECT * FROM reader_annotations WHERE syncDirty = 1")
    suspend fun getDirty(): List<ReaderAnnotation>

    @Query("SELECT * FROM reader_annotations WHERE bookId = :bookId AND syncDirty = 1")
    suspend fun getDirtyForBook(bookId: String): List<ReaderAnnotation>

    @Query("SELECT * FROM reader_annotations WHERE bookId = :bookId AND providerSource = :providerSource AND syncDirty = 1")
    suspend fun getDirtyForBookAndProvider(bookId: String, providerSource: String): List<ReaderAnnotation>

    @Query("SELECT DISTINCT bookId FROM reader_annotations WHERE syncDirty = 1")
    suspend fun getDirtyBookIds(): List<String>

    @Query("UPDATE reader_annotations SET syncDirty = 0, syncEtag = :etag, serverId = COALESCE(:serverId, serverId) WHERE id = :id")
    suspend fun markClean(id: String, etag: String?, serverId: String?)

    @Query("UPDATE reader_annotations SET bookId = :targetBookId, updatedAt = :now, syncDirty = 1 WHERE bookId = :sourceBookId")
    suspend fun moveBook(sourceBookId: String, targetBookId: String, now: Long)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(a: ReaderAnnotation)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(list: List<ReaderAnnotation>)

    @Update
    suspend fun update(a: ReaderAnnotation)

    @Query("UPDATE reader_annotations SET deletedAt = :now, updatedAt = :now, syncDirty = 1 WHERE id = :id")
    suspend fun softDelete(id: String, now: Long = System.currentTimeMillis())

    @Query("UPDATE reader_annotations SET deletedAt = NULL, updatedAt = :now, syncDirty = 1 WHERE id = :id")
    suspend fun restore(id: String, now: Long = System.currentTimeMillis())

    @Delete
    suspend fun delete(a: ReaderAnnotation)

    @Query("DELETE FROM reader_annotations WHERE id = :id")
    suspend fun purge(id: String)

    @Query("DELETE FROM reader_annotations WHERE bookId = :bookId AND providerSource = :providerSource AND syncDirty = 0")
    suspend fun purgeCleanProviderRows(bookId: String, providerSource: String)

    @Query("DELETE FROM reader_annotations WHERE bookId = :bookId AND providerSource = :providerSource AND syncDirty = 0 AND serverId NOT IN (:serverIds)")
    suspend fun purgeCleanProviderRowsMissing(
        bookId: String,
        providerSource: String,
        serverIds: List<String>,
    )

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(a: ReaderAnnotation)
}
