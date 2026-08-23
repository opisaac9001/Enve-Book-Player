package com.enve.app.playback

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import com.enve.engine.impl.R
import com.enve.app.data.offline.OfflineAudioStorage
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.core.data.remote.ConnectionScope
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext

@HiltWorker
class AudiobookDownloadWorker @AssistedInject constructor(
    @Assisted appContext: Context,
    @Assisted params: WorkerParameters,
    private val manager: OfflineDownloadManager,
    private val storage: OfflineAudioStorage,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val bookId = inputData.getString(KEY_BOOK_ID) ?: return Result.failure()
        val book = storage.getPendingRequest(bookId) ?: return Result.failure()

        setForeground(foregroundInfo(book.title))

        val scopeElement = book.connectionId?.let { ConnectionScope.asContextElement(it) }
        return try {
            val ok = if (scopeElement != null) {
                withContext(scopeElement) { manager.runDownload(book) }
            } else {
                manager.runDownload(book)
            }
            if (ok) Result.success() else Result.retry()
        } catch (e: CancellationException) {

            Result.failure()
        }
    }

    private fun foregroundInfo(title: String): ForegroundInfo {
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setContentTitle(applicationContext.getString(R.string.download_notification_title))
            .setContentText(applicationContext.getString(R.string.download_notification_text, title))
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
        const val CHANNEL_ID = "enve_downloads"
        const val KEY_BOOK_ID = "book_id"
        private const val NOTIFICATION_ID = 0xD0
    }
}
