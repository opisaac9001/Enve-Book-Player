package com.enve.app.data.metadata

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query

@Entity(
    tableName = "matched_book_metadata",
    indices = [
        Index("bookId"),
        Index("source"),
        Index("updatedAt"),
    ],
)
data class MatchedBookMetadata(
    @PrimaryKey val metadataKey: String,
    val bookId: String,
    val source: String,
    val mediaType: String,
    val matchSource: String,
    val externalId: String,
    val title: String?,
    val subtitle: String?,
    val author: String?,
    val narrator: String?,
    val publisher: String?,
    val publishedDate: String?,
    val publishedYear: Int?,
    val isbn: String?,
    val coverUrl: String?,
    val durationSec: Long?,
    val pageCount: Int?,
    val seriesName: String?,
    val seriesNumber: String?,
    val description: String?,
    val categoriesJson: String,
    val language: String?,
    val rawJson: String?,
    val updatedAt: Long,
)

@Dao
interface MatchedBookMetadataDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(metadata: MatchedBookMetadata)

    @Query("SELECT * FROM matched_book_metadata WHERE metadataKey = :metadataKey LIMIT 1")
    suspend fun get(metadataKey: String): MatchedBookMetadata?

    @Query("SELECT * FROM matched_book_metadata WHERE metadataKey IN (:metadataKeys)")
    suspend fun getForKeys(metadataKeys: List<String>): List<MatchedBookMetadata>

    @Query("DELETE FROM matched_book_metadata WHERE metadataKey = :metadataKey")
    suspend fun delete(metadataKey: String)
}
