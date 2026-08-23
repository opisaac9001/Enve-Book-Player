package com.enve.app.data.librarian

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.enve.engine.impl.R
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import java.io.IOException
import kotlinx.coroutines.CancellationException

@HiltWorker
class LibrarianModelDownloadWorker @AssistedInject constructor(
    @Assisted appContext: Context,
    @Assisted params: WorkerParameters,
    private val engineManager: LibrarianEngineManager,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        setForeground(foregroundInfo())
        return try {
            engineManager.downloadRecommendedLiteRtModel { progress ->
                setProgress(workDataOf(KEY_PROGRESS to progress))
            }
            engineManager.savePreference(LibrarianEnginePreference.LITERT_LM)
            Result.success()
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            if (runAttemptCount < MAX_RETRIES) Result.retry() else failure(e)
        } catch (e: Exception) {
            failure(e)
        }
    }

    private fun failure(e: Exception): Result =
        Result.failure(workDataOf(KEY_ERROR to (e.message ?: "Recommended model download failed.")))

    private fun foregroundInfo(): ForegroundInfo {
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setContentTitle(applicationContext.getString(R.string.librarian_model_notification_title))
            .setContentText(engineManager.recommendedModel.title)
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setProgress(0, 0, true)
            .build()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val KEY_PROGRESS = "progress"
        const val KEY_ERROR = "error"
        private const val CHANNEL_ID = "enve_downloads"
        private const val NOTIFICATION_ID = 0xD1
        private const val MAX_RETRIES = 5
    }
}
