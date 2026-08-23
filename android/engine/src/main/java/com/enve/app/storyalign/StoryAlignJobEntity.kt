package com.enve.app.storyalign

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Entity(
    tableName = "story_align_jobs",
    indices = [
        Index("status"),
        Index("createdAt"),
    ],
)
data class StoryAlignJobEntity(
    @PrimaryKey val id: String,
    val ebookKey: String,
    val audiobookKey: String,
    val ebookTitle: String,
    val audiobookTitle: String,
    val author: String?,
    val connectionId: String?,
    val status: String,
    val stage: String,
    val stageProgress: Float,
    val overallProgress: Float,
    val settingsJson: String,
    val sessionDir: String,
    val outputPath: String?,
    val outputBookId: String?,
    val reportJson: String?,
    val errorMessage: String?,
    val errorStage: String?,
    val createdAt: Long,
    val updatedAt: Long,
)

@Dao
interface StoryAlignJobDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(job: StoryAlignJobEntity)

    @Query("SELECT * FROM story_align_jobs WHERE id = :id")
    suspend fun getById(id: String): StoryAlignJobEntity?

    @Query("SELECT * FROM story_align_jobs ORDER BY createdAt DESC")
    fun observeAll(): Flow<List<StoryAlignJobEntity>>

    @Query("SELECT * FROM story_align_jobs WHERE status IN ('QUEUED', 'RUNNING', 'PAUSED')")
    suspend fun activeJobs(): List<StoryAlignJobEntity>

    @Query("DELETE FROM story_align_jobs WHERE id = :id")
    suspend fun delete(id: String)
}
