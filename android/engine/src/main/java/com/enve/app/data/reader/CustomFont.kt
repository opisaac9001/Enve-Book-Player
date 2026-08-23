package com.enve.app.data.reader

import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Entity(tableName = "custom_fonts")
data class CustomFont(
    @PrimaryKey val id: String,
    @ColumnInfo val displayName: String,
    @ColumnInfo val regularPath: String? = null,
    @ColumnInfo val boldPath: String? = null,
    @ColumnInfo val italicPath: String? = null,
    @ColumnInfo val boldItalicPath: String? = null,
    @ColumnInfo val addedAt: Long,
)

@Dao
interface CustomFontDao {
    @Query("SELECT * FROM custom_fonts ORDER BY displayName COLLATE NOCASE")
    fun observeAll(): Flow<List<CustomFont>>

    @Query("SELECT * FROM custom_fonts ORDER BY displayName COLLATE NOCASE")
    suspend fun getAll(): List<CustomFont>

    @Query("SELECT * FROM custom_fonts WHERE id = :id")
    suspend fun get(id: String): CustomFont?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(font: CustomFont)

    @Query("DELETE FROM custom_fonts WHERE id = :id")
    suspend fun delete(id: String)
}
