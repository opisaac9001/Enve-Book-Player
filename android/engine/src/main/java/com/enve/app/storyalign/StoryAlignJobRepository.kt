package com.enve.app.storyalign

import com.enve.engine.storyalign.StoryAlignStage
import com.enve.engine.storyalign.StoryAlignStatus
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class StoryAlignJobRepository @Inject constructor(
    private val dao: StoryAlignJobDao,
) {
    val jobs: Flow<List<StoryAlignJobEntity>> = dao.observeAll()

    suspend fun get(id: String): StoryAlignJobEntity? = dao.getById(id)
    suspend fun upsert(job: StoryAlignJobEntity) = dao.upsert(job)
    suspend fun delete(id: String) = dao.delete(id)
    suspend fun activeJobs(): List<StoryAlignJobEntity> = dao.activeJobs()

    suspend fun updateProgress(
        id: String,
        status: StoryAlignStatus,
        stage: StoryAlignStage,
        stageProgress: Float,
        overallProgress: Float,
    ) {
        val job = dao.getById(id) ?: return
        dao.upsert(
            job.copy(
                status = status.name,
                stage = stage.name,
                stageProgress = stageProgress,
                overallProgress = overallProgress,
                updatedAt = System.currentTimeMillis(),
            ),
        )
    }

    suspend fun markDone(id: String, outputPath: String?, outputBookId: String?, reportJson: String?) {
        val job = dao.getById(id) ?: return
        dao.upsert(
            job.copy(
                status = StoryAlignStatus.DONE.name,
                stage = StoryAlignStage.REGISTER.name,
                stageProgress = 1f,
                overallProgress = 1f,
                outputPath = outputPath,
                outputBookId = outputBookId,
                reportJson = reportJson,
                errorMessage = null,
                errorStage = null,
                updatedAt = System.currentTimeMillis(),
            ),
        )
    }

    suspend fun markFailed(id: String, message: String) {
        val job = dao.getById(id) ?: return
        dao.upsert(
            job.copy(
                status = StoryAlignStatus.FAILED.name,
                errorMessage = message,
                errorStage = job.stage,
                updatedAt = System.currentTimeMillis(),
            ),
        )
    }

    suspend fun markCancelled(id: String) {
        val job = dao.getById(id) ?: return
        val status = runCatching { StoryAlignStatus.valueOf(job.status) }.getOrNull()
        if (status == StoryAlignStatus.DONE || status == StoryAlignStatus.FAILED) return
        dao.upsert(job.copy(status = StoryAlignStatus.CANCELLED.name, updatedAt = System.currentTimeMillis()))
    }

    suspend fun resetForRetry(id: String) {
        val job = dao.getById(id) ?: return
        dao.upsert(
            job.copy(
                status = StoryAlignStatus.QUEUED.name,
                stage = StoryAlignStage.DOWNLOAD.name,
                stageProgress = 0f,
                overallProgress = 0f,
                errorMessage = null,
                errorStage = null,
                updatedAt = System.currentTimeMillis(),
            ),
        )
    }
}
