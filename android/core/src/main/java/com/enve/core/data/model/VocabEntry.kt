package com.enve.core.data.model

import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Entity(
    tableName = "vocab_entries",
    indices = [Index("bookStableId"), Index("nextReviewAt"), Index("lookedUpAt")],
)
data class VocabEntry(
    @PrimaryKey val id: String,
    @ColumnInfo val bookStableId: String,
    @ColumnInfo val word: String,
    @ColumnInfo val sentence: String,
    @ColumnInfo val sentenceBefore: String = "",
    @ColumnInfo val sentenceAfter: String = "",
    @ColumnInfo val locator: String? = null,
    @ColumnInfo val position: Double = 0.0,
    @ColumnInfo val chapterTitle: String? = null,
    @ColumnInfo val definitionSnapshot: String? = null,
    @ColumnInfo val userNote: String? = null,
    @ColumnInfo val lookedUpAt: Long = System.currentTimeMillis(),
    @ColumnInfo val tags: String = "",
    @ColumnInfo val sourceLanguage: String? = null,
    @ColumnInfo val studyBox: Int = 0,
    @ColumnInfo val nextReviewAt: Long? = null,
    @ColumnInfo val lastReviewedAt: Long? = null,
    @ColumnInfo val reviewStreak: Int = 0,
) {
    fun isDue(now: Long = System.currentTimeMillis()): Boolean =
        studyBox < 5 && (nextReviewAt == null || nextReviewAt <= now)

    val isNew: Boolean get() = studyBox == 0 && nextReviewAt == null
    val isMastered: Boolean get() = studyBox >= 5
}

@Dao
interface VocabEntryDao {

    @Query("SELECT * FROM vocab_entries ORDER BY lookedUpAt DESC")
    fun observeAll(): Flow<List<VocabEntry>>

    @Query("SELECT * FROM vocab_entries ORDER BY lookedUpAt DESC")
    suspend fun getAll(): List<VocabEntry>

    @Query("SELECT * FROM vocab_entries WHERE id = :id LIMIT 1")
    suspend fun getById(id: String): VocabEntry?

    @Query("SELECT COUNT(*) FROM vocab_entries")
    fun observeCount(): Flow<Int>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entry: VocabEntry)

    @Query("DELETE FROM vocab_entries WHERE id = :id")
    suspend fun delete(id: String)

    @Query("""
        UPDATE vocab_entries
           SET studyBox = :box, nextReviewAt = :nextReviewAt,
               lastReviewedAt = :reviewedAt, reviewStreak = :streak
         WHERE id = :id
    """)
    suspend fun applyReview(
        id: String,
        box: Int,
        nextReviewAt: Long?,
        reviewedAt: Long,
        streak: Int,
    )

    @Query("UPDATE vocab_entries SET userNote = :note, definitionSnapshot = :definition WHERE id = :id")
    suspend fun updateNoteAndDefinition(id: String, note: String?, definition: String?)

    @Query("UPDATE vocab_entries SET definitionSnapshot = :definition WHERE id = :id")
    suspend fun updateDefinition(id: String, definition: String?)

    @Query("UPDATE vocab_entries SET bookStableId = :targetBookStableId WHERE bookStableId = :sourceBookStableId")
    suspend fun moveBookEntries(sourceBookStableId: String, targetBookStableId: String)
}
