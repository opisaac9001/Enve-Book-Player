package com.enve.app.data.model

import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

enum class AnnotationStyle {
    HIGHLIGHT, UNDERLINE, STRIKETHROUGH, SQUIGGLY;

    val label: String get() = when (this) {
        HIGHLIGHT     -> "Highlight"
        UNDERLINE     -> "Underline"
        STRIKETHROUGH -> "Strike"
        SQUIGGLY      -> "Squiggle"
    }
}

@Entity(tableName = "reader_annotations")
data class ReaderAnnotation(
    @PrimaryKey val id:          String,
    @ColumnInfo val bookId:      String,
    @ColumnInfo val locatorJson: String,
    @ColumnInfo val style:       String = AnnotationStyle.HIGHLIGHT.name,
    @ColumnInfo val colorHex:    String = "#FFF59D",
    @ColumnInfo val note:        String = "",
    @ColumnInfo val selectedText:String = "",
    @ColumnInfo val createdAt:   Long   = System.currentTimeMillis(),
)

@Dao
interface ReaderAnnotationDao {
    @Query("SELECT * FROM reader_annotations WHERE bookId = :bookId ORDER BY createdAt DESC")
    fun flowByBook(bookId: String): Flow<List<ReaderAnnotation>>

    @Query("SELECT * FROM reader_annotations WHERE bookId = :bookId ORDER BY createdAt DESC")
    suspend fun getByBook(bookId: String): List<ReaderAnnotation>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(a: ReaderAnnotation)

    @Update
    suspend fun update(a: ReaderAnnotation)

    @Delete
    suspend fun delete(a: ReaderAnnotation)
}