package com.enve.app.data.reader

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

@Entity(tableName = "layout_presets")
data class LayoutPreset(
    @PrimaryKey val id: String,
    @ColumnInfo val name: String,
    @ColumnInfo val theme: String = "DARK",
    @ColumnInfo val fontFamily: String = "SERIF",
    @ColumnInfo val fontSize: Float = 1.0f,
    @ColumnInfo val lineHeight: Float = 1.4f,
    @ColumnInfo val pageMargins: Float = 1.0f,
    @ColumnInfo val wordSpacing: Float = 0f,
    @ColumnInfo val letterSpacing: Float = 0f,
    @ColumnInfo val fontWeight: Float = 1.0f,
    @ColumnInfo val paragraphSpacing: Float = 0f,
    @ColumnInfo val paragraphIndent: Float = 0f,
    @ColumnInfo val scroll: Boolean = false,
    @ColumnInfo val publisherStyles: Boolean = true,
    @ColumnInfo val justified: Boolean = true,
    @ColumnInfo val columnCount: String = "AUTO",
    @ColumnInfo val createdAt: Long = System.currentTimeMillis(),
)

@Dao
interface LayoutPresetDao {
    @Query("SELECT * FROM layout_presets ORDER BY createdAt DESC")
    fun flowAll(): Flow<List<LayoutPreset>>

    @Query("SELECT * FROM layout_presets ORDER BY createdAt DESC")
    suspend fun getAll(): List<LayoutPreset>

    @Query("SELECT * FROM layout_presets WHERE id = :id")
    suspend fun getById(id: String): LayoutPreset?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(preset: LayoutPreset)

    @Update
    suspend fun update(preset: LayoutPreset)

    @Delete
    suspend fun delete(preset: LayoutPreset)
}
