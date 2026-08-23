package com.enve.core.data.local

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.enve.core.data.model.BookSource

@Entity(
    tableName = "pending_progress_push",
    primaryKeys = ["source", "connectionKey", "bookId"],
)
data class PendingProgressPush(
    val bookId: String,
    val source: String = BookSource.GRIMMORY.name,
    val connectionKey: String = "",
    val mediaType: String,
    val percentage: Float,
    val isFinished: Boolean,
    val createdAt: Long,
    val attempts: Int = 1,
    val lastAttemptAt: Long = 0L,
    val lastError: String? = null,
)

@Dao
interface PendingProgressPushDao {
    @Query("SELECT * FROM pending_progress_push ORDER BY createdAt ASC")
    suspend fun getAll(): List<PendingProgressPush>

    @Query("SELECT * FROM pending_progress_push WHERE bookId = :bookId AND source = :source AND connectionKey = :connectionKey LIMIT 1")
    suspend fun get(bookId: String, source: String, connectionKey: String): PendingProgressPush?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(item: PendingProgressPush)

    @Query("DELETE FROM pending_progress_push WHERE bookId = :bookId AND source = :source AND connectionKey = :connectionKey")
    suspend fun delete(bookId: String, source: String, connectionKey: String)

    @Query("DELETE FROM pending_progress_push WHERE createdAt < :cutoffEpochMs")
    suspend fun pruneOlderThan(cutoffEpochMs: Long)
}
