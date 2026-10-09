package com.enve.app.storyalign

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.di.ApplicationScope
import com.enve.engine.storyalign.StoryAlignSettings
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.serialization.json.Json
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class StoryAlignJobScheduler @Inject constructor(
    @ApplicationContext private val context: Context,
    private val locations: ProfileStorageLocations,
    private val repository: StoryAlignJobRepository,
    @ApplicationScope private val scope: CoroutineScope,
) {
    private val lock = Any()
    private var accepting = true
    private val active = mutableSetOf<Job>()
    private val json = Json { ignoreUnknownKeys = true }
    private val workTag get() = if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) StoryAlignWorker.WORK_TAG
        else "profile:${locations.profileId}:storyalign"

    fun enqueue(id: String, settings: StoryAlignSettings, policy: ExistingWorkPolicy) = synchronized(lock) {
        check(accepting) { "StoryAlign is paused for this profile." }
        val constraints = Constraints.Builder().setRequiresStorageNotLow(true)
            .apply { if (!settings.allowOnBattery) setRequiresCharging(true) }.build()
        val request = OneTimeWorkRequestBuilder<StoryAlignWorker>()
            .setConstraints(constraints)
            .setInputData(Data.Builder().putString(StoryAlignWorker.KEY_JOB_ID, id)
                .putString(StoryAlignWorker.KEY_PROFILE_ID, locations.profileId).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(workTag)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(workName(id), policy, request)
    }

    fun cancel(id: String) {
        WorkManager.getInstance(context).cancelUniqueWork(workName(id))
    }

    suspend fun <T> runCaptured(block: suspend () -> T): T = coroutineScope {
        val job = checkNotNull(coroutineContext[Job])
        synchronized(lock) {
            if (!accepting) throw CancellationException("Profile is paused")
            active += job
        }
        try {
            block()
        } finally {
            synchronized(lock) { active -= job }
        }
    }

    suspend fun pauseAllAndAwait() {
        val jobs = synchronized(lock) { accepting = false; active.toList() }
        runInterruptible(Dispatchers.IO) { WorkManager.getInstance(context).cancelAllWorkByTag(workTag).result.get() }
        jobs.forEach { it.cancelAndJoin() }
    }

    fun resume() {
        synchronized(lock) { accepting = true }
        scope.launch {
            repository.activeJobs().forEach { job ->
                val settings = json.decodeFromString(StoryAlignSettings.serializer(), job.settingsJson)
                synchronized(lock) {
                    if (accepting) enqueue(job.id, settings, ExistingWorkPolicy.KEEP)
                }
            }
        }
    }

    private fun workName(id: String): String = if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) "storyalign:$id"
        else "profile:${locations.profileId}:storyalign:$id"
}
