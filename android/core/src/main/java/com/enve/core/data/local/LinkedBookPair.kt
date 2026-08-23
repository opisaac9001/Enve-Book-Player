package com.enve.core.data.local

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Entity(
    tableName = "linked_book_pairs",
    indices = [
        Index("audiobookKey"),
        Index("updatedAt"),
    ],
)
data class LinkedBookPair(
    @PrimaryKey val ebookKey: String,
    val audiobookKey: String,
    val chapterOffset: Int = 0,
    val updatedAt: Long = 0L,
)

@Dao
interface LinkedBookPairDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(pair: LinkedBookPair)

    @Query("SELECT * FROM linked_book_pairs WHERE ebookKey = :ebookKey LIMIT 1")
    suspend fun getForEbook(ebookKey: String): LinkedBookPair?

    @Query("SELECT * FROM linked_book_pairs WHERE audiobookKey = :audiobookKey LIMIT 1")
    suspend fun getForAudiobook(audiobookKey: String): LinkedBookPair?

    @Query("SELECT * FROM linked_book_pairs WHERE ebookKey = :ebookKey LIMIT 1")
    fun observeForEbook(ebookKey: String): Flow<LinkedBookPair?>

    @Query("SELECT * FROM linked_book_pairs ORDER BY updatedAt DESC")
    fun observeAll(): Flow<List<LinkedBookPair>>

    @Query("DELETE FROM linked_book_pairs WHERE ebookKey = :ebookKey")
    suspend fun deleteForEbook(ebookKey: String)

    @Query("DELETE FROM linked_book_pairs WHERE audiobookKey = :audiobookKey")
    suspend fun deleteForAudiobook(audiobookKey: String)

    @Query("DELETE FROM linked_book_pairs")
    suspend fun clearAll()
}
