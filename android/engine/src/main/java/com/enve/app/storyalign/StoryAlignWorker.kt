package com.enve.app.storyalign

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import com.enve.engine.impl.R
import com.enve.engine.storyalign.StoryAlignSettings
import com.enve.engine.storyalign.StoryAlignStage
import com.enve.engine.storyalign.StoryAlignStatus
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

@HiltWorker
class StoryAlignWorker @AssistedInject constructor(
    @Assisted appContext: Context,
    @Assisted params: WorkerParameters,
    private val repo: StoryAlignJobRepository,
    private val generator: StoryAlignGenerator,
) : CoroutineWorker(appContext, params) {

    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun doWork(): Result {
        val jobId = inputData.getString(KEY_JOB_ID) ?: return Result.failure()
        val job = repo.get(jobId) ?: return Result.failure()
        val status = runCatching { StoryAlignStatus.valueOf(job.status) }.getOrNull()
        if (status == StoryAlignStatus.DONE || status == StoryAlignStatus.CANCELLED) return Result.success()

        setForeground(foregroundInfo(job.ebookTitle, 0f))

        return try {
            val settings = runCatching {
                json.decodeFromString(StoryAlignSettings.serializer(), job.settingsJson)
            }.getOrDefault(StoryAlignSettings())
            val sink = StoryAlignGenerator.ProgressSink { stage, stageProgress, overall ->
                if (isStopped) throw CancellationException("Work stopped")
                repo.updateProgress(jobId, StoryAlignStatus.RUNNING, stage, stageProgress, overall)
                setForeground(foregroundInfo(job.ebookTitle, overall))
            }
            val result = generator.generate(job, settings, sink)
            val reportJson = """{"alignedSentences":${result.alignedSentences},"totalSentences":${result.totalSentences}}"""
            repo.markDone(jobId, outputPath = result.outputPath, outputBookId = result.outputBookId, reportJson = reportJson)
            Result.success()
        } catch (e: CancellationException) {

            withContext(NonCancellable) {
                val current = repo.get(jobId)
                if (current != null && current.status != StoryAlignStatus.CANCELLED.name) {
                    repo.updateProgress(
                        jobId,
                        StoryAlignStatus.QUEUED,
                        runCatching { StoryAlignStage.valueOf(current.stage) }.getOrDefault(StoryAlignStage.DOWNLOAD),
                        current.stageProgress,
                        current.overallProgress,
                    )
                }
            }
            throw e
        } catch (e: Exception) {
            repo.markFailed(jobId, e.message ?: "Generation failed")
            Result.failure()
        }
    }

    private fun foregroundInfo(title: String, progress: Float): ForegroundInfo {
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setContentTitle(applicationContext.getString(R.string.storyalign_notification_title))
            .setContentText(applicationContext.getString(R.string.storyalign_notification_text, title))
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setProgress(100, (progress * 100).toInt(), false)
            .build()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val CHANNEL_ID = "enve_storyalign"
        const val KEY_JOB_ID = "job_id"
        const val WORK_TAG = "storyalign"
        private const val NOTIFICATION_ID = 0xD1
    }
}
