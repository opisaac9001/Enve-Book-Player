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
    tableName = "custom_smart_collections",
    indices = [
        Index("updatedAt"),
    ],
)
data class CustomSmartCollection(
    @PrimaryKey val id: String,
    val name: String,
    val description: String?,
    val mediaType: String?,
    val status: String,
    val length: String,
    val addedWithinDays: Int?,
    val query: String?,
    val createdAt: Long,
    val updatedAt: Long,
)

@Dao
interface CustomSmartCollectionDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(collection: CustomSmartCollection)

    @Query("SELECT * FROM custom_smart_collections ORDER BY updatedAt DESC")
    suspend fun getAll(): List<CustomSmartCollection>

    @Query("SELECT * FROM custom_smart_collections ORDER BY updatedAt DESC")
    fun observeAll(): Flow<List<CustomSmartCollection>>

    @Query("SELECT * FROM custom_smart_collections WHERE id = :id LIMIT 1")
    suspend fun get(id: String): CustomSmartCollection?

    @Query("DELETE FROM custom_smart_collections WHERE id = :id")
    suspend fun delete(id: String)
}
