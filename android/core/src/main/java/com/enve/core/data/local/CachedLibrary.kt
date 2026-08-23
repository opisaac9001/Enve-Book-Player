package com.enve.core.data.local

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import kotlinx.coroutines.flow.Flow

@Entity(tableName = "library_cache")
data class CachedLibrary(
    @PrimaryKey val id: String,
    val name: String,
    val source: String,
    val connectionId: String?,
    val bookCount: Int,
    val cachedAt: Long,
)

@Dao
interface LibraryCacheDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(libraries: List<CachedLibrary>)

    @Query("SELECT * FROM library_cache ORDER BY name COLLATE NOCASE ASC")
    fun observeAll(): Flow<List<CachedLibrary>>

    @Query("SELECT * FROM library_cache ORDER BY name COLLATE NOCASE ASC")
    suspend fun getAll(): List<CachedLibrary>

    @Query("DELETE FROM library_cache WHERE connectionId = :connectionId")
    suspend fun deleteByConnection(connectionId: String)

    @Query("DELETE FROM library_cache")
    suspend fun clearAll()
}

fun CachedLibrary.toLibrary(): Library = Library(
    id = id,
    name = name,
    bookCount = bookCount,
    source = runCatching { BookSource.valueOf(source) }.getOrDefault(BookSource.GRIMMORY),
    connectionId = connectionId,
)

fun Library.toCached(nowMs: Long = System.currentTimeMillis()): CachedLibrary = CachedLibrary(
    id = id,
    name = name,
    source = source.name,
    connectionId = connectionId,
    bookCount = bookCount,
    cachedAt = nowMs,
)
