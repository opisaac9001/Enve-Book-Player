package com.enve.core.data.local

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Chapter
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Entity(tableName = "book_extras")
data class BookExtras(
    @PrimaryKey val cacheKey: String,
    val chaptersJson: String = "[]",
    val audioTracksJson: String = "[]",
    val updatedAt: Long = 0L,
)

@Dao
interface BookExtrasDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(extras: BookExtras)

    @Query("SELECT * FROM book_extras WHERE cacheKey = :cacheKey")
    suspend fun get(cacheKey: String): BookExtras?

    @Query("DELETE FROM book_extras WHERE cacheKey = :cacheKey")
    suspend fun delete(cacheKey: String)

    @Query("DELETE FROM book_extras")
    suspend fun clearAll()
}

fun bookExtrasCacheKey(connectionId: String?, source: String, id: String): String =
    "${connectionId ?: source}:$id"

private val bookExtrasJson = Json { ignoreUnknownKeys = true }

fun BookExtras.decodeChapters(): List<Chapter> =
    runCatching { bookExtrasJson.decodeFromString<List<Chapter>>(chaptersJson) }
        .getOrDefault(emptyList())

fun encodeChaptersJson(chapters: List<Chapter>): String =
    runCatching { bookExtrasJson.encodeToString(chapters) }.getOrDefault("[]")

fun BookExtras.decodeAudioTracks(): List<AudioTrack> =
    runCatching { bookExtrasJson.decodeFromString<List<AudioTrack>>(audioTracksJson) }
        .getOrDefault(emptyList())

fun encodeAudioTracksJson(tracks: List<AudioTrack>): String =
    runCatching { bookExtrasJson.encodeToString(tracks) }.getOrDefault("[]")
