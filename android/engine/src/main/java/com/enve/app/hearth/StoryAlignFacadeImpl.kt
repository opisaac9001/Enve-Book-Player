package com.enve.app.hearth

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.enve.app.data.links.BookLinkRepository
import com.enve.app.storyalign.StoryAlignJobEntity
import com.enve.app.storyalign.StoryAlignJobRepository
import com.enve.app.storyalign.StoryAlignWorker
import com.enve.core.data.local.LinkedBookPair
import com.enve.core.data.model.Book
import com.enve.engine.storyalign.StoryAlignFacade
import com.enve.engine.storyalign.StoryAlignJobUi
import com.enve.engine.storyalign.StoryAlignPairUi
import com.enve.engine.storyalign.StoryAlignSettings
import com.enve.engine.storyalign.StoryAlignStage
import com.enve.engine.storyalign.StoryAlignStatus
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class StoryAlignFacadeImpl @Inject constructor(
    @ApplicationContext private val context: Context,
    private val repo: StoryAlignJobRepository,
    private val bookLinks: BookLinkRepository,
) : StoryAlignFacade {

    private val json = Json { ignoreUnknownKeys = true }

    override val jobs: Flow<List<StoryAlignJobUi>> =
        repo.jobs.map { list -> list.map { it.toUi() } }

    override val candidatePairs: Flow<List<StoryAlignPairUi>> =
        bookLinks.observeLinkedPairs()
            .map { pairs -> pairs.mapNotNull { p -> bookLinks.resolvePair(p)?.let { (e, a) -> ResolvedPair(p.ebookKey, p.audiobookKey, e, a) } } }
            .combine(repo.jobs) { resolved, jobs ->
                resolved.map { r ->
                    StoryAlignPairUi(
                        ebookKey = r.ebookKey,
                        audiobookKey = r.audiobookKey,
                        title = r.ebook.title,
                        author = r.ebook.author,
                        coverUrl = r.ebook.coverUrl ?: r.audiobook.coverUrl,
                        hasJob = jobs.any { it.ebookKey == r.ebookKey && it.audiobookKey == r.audiobookKey },
                    )
                }
            }

    override suspend fun createJob(ebookKey: String, audiobookKey: String, settings: StoryAlignSettings): String {
        val resolved = bookLinks.resolvePair(LinkedBookPair(ebookKey = ebookKey, audiobookKey = audiobookKey))
        val ebook = resolved?.first
        val audiobook = resolved?.second
        val id = UUID.randomUUID().toString()
        val now = System.currentTimeMillis()
        val entity = StoryAlignJobEntity(
            id = id,
            ebookKey = ebookKey,
            audiobookKey = audiobookKey,
            ebookTitle = ebook?.title ?: ebookKey,
            audiobookTitle = audiobook?.title ?: audiobookKey,
            author = ebook?.author,
            connectionId = audiobook?.connectionId ?: ebook?.connectionId,
            status = StoryAlignStatus.QUEUED.name,
            stage = StoryAlignStage.DOWNLOAD.name,
            stageProgress = 0f,
            overallProgress = 0f,
            settingsJson = json.encodeToString(StoryAlignSettings.serializer(), settings),
            sessionDir = File(context.filesDir, "storyalign/$id").absolutePath,
            outputPath = null,
            outputBookId = null,
            reportJson = null,
            errorMessage = null,
            errorStage = null,
            createdAt = now,
            updatedAt = now,
        )
        repo.upsert(entity)
        enqueue(id, settings, ExistingWorkPolicy.KEEP)
        return id
    }

    override suspend fun cancelJob(jobId: String) {

        repo.markCancelled(jobId)
        WorkManager.getInstance(context).cancelUniqueWork(workName(jobId))
    }

    override suspend fun retryJob(jobId: String) {
        val job = repo.get(jobId) ?: return
        val settings = runCatching {
            json.decodeFromString(StoryAlignSettings.serializer(), job.settingsJson)
        }.getOrDefault(StoryAlignSettings())
        repo.resetForRetry(jobId)
        enqueue(jobId, settings, ExistingWorkPolicy.REPLACE)
    }

    override suspend fun deleteJob(jobId: String, deleteOutput: Boolean) {
        WorkManager.getInstance(context).cancelUniqueWork(workName(jobId))
        val job = repo.get(jobId)
        repo.delete(jobId)
        if (job != null) {
            File(job.sessionDir).deleteRecursively()
            if (deleteOutput) job.outputPath?.let { File(it).delete() }
        }
    }

    private fun enqueue(jobId: String, settings: StoryAlignSettings, policy: ExistingWorkPolicy) {
        val constraints = Constraints.Builder()
            .setRequiresStorageNotLow(true)
            .apply { if (!settings.allowOnBattery) setRequiresCharging(true) }
            .build()
        val request = OneTimeWorkRequestBuilder<StoryAlignWorker>()
            .setConstraints(constraints)
            .setInputData(Data.Builder().putString(StoryAlignWorker.KEY_JOB_ID, jobId).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(StoryAlignWorker.WORK_TAG)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(workName(jobId), policy, request)
    }

    private fun workName(jobId: String) = "storyalign:$jobId"

    private fun StoryAlignJobEntity.toUi() = StoryAlignJobUi(
        id = id,
        ebookTitle = ebookTitle,
        audiobookTitle = audiobookTitle,
        author = author,
        status = runCatching { StoryAlignStatus.valueOf(status) }.getOrDefault(StoryAlignStatus.QUEUED),
        stage = runCatching { StoryAlignStage.valueOf(stage) }.getOrDefault(StoryAlignStage.DOWNLOAD),
        stageProgress = stageProgress,
        overallProgress = overallProgress,
        errorMessage = errorMessage,
        outputBookId = outputBookId,
        createdAt = createdAt,
        updatedAt = updatedAt,
    )

    private data class ResolvedPair(
        val ebookKey: String,
        val audiobookKey: String,
        val ebook: Book,
        val audiobook: Book,
    )
}
