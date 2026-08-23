package com.enve.core.data.local

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import com.enve.core.data.model.Book
import kotlinx.coroutines.flow.Flow

@Entity(
    tableName = "book_metadata_overrides",
    indices = [
        Index("updatedAt"),
    ],
)
data class BookMetadataOverride(
    @PrimaryKey val bookKey: String,
    val title: String,
    val subtitle: String?,
    val author: String?,
    val narrator: String?,
    val description: String?,
    val seriesName: String?,
    val seriesNumber: String?,
    val publisher: String?,
    val publishedDate: String?,
    val isbn13: String?,
    val language: String?,
    val pageCount: Int?,
    val updatedAt: Long,
)

@Dao
interface BookMetadataOverrideDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(override: BookMetadataOverride)

    @Query("SELECT * FROM book_metadata_overrides WHERE bookKey = :bookKey LIMIT 1")
    suspend fun getForBook(bookKey: String): BookMetadataOverride?

    @Query("SELECT * FROM book_metadata_overrides")
    suspend fun getAll(): List<BookMetadataOverride>

    @Query("SELECT * FROM book_metadata_overrides")
    fun observeAll(): Flow<List<BookMetadataOverride>>

    @Query("DELETE FROM book_metadata_overrides WHERE bookKey = :bookKey")
    suspend fun deleteForBook(bookKey: String)

    @Query("DELETE FROM book_metadata_overrides WHERE bookKey IN (:bookKeys)")
    suspend fun deleteForBooks(bookKeys: List<String>)

    @Query("DELETE FROM book_metadata_overrides")
    suspend fun clearAll()
}

fun Book.withMetadataOverride(override: BookMetadataOverride?): Book {
    if (override == null) return this
    return copy(
        title = override.title,
        subtitle = override.subtitle,
        author = override.author,
        narrator = override.narrator,
        description = override.description,
        seriesName = override.seriesName,
        seriesNumber = override.seriesNumber,
        publisher = override.publisher,
        publishedDate = override.publishedDate,
        isbn13 = override.isbn13,
        language = override.language,
        pageCount = override.pageCount,
    )
}
