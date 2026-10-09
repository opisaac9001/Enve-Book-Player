package com.enve.wear.listening

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import androidx.core.app.NotificationCompat
import androidx.work.*
import com.enve.wear.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import kotlin.coroutines.coroutineContext

class WatchDownloadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = downloadLock.withLock { withContext(Dispatchers.IO) {
        val key = inputData.getString("key") ?: return@withContext Result.failure()
        val store = WatchLibraryStore.get(applicationContext)
        val book = store.state.value.books.firstOrNull { it.key == key } ?: return@withContext Result.failure()
        val vault = CredentialVault(applicationContext)
        val account = vault.read(book.account) ?: return@withContext Result.failure(workDataOf("error" to "Sign in to this book’s account."))
        try {
            setForeground(foreground(book.title))
            val provider = WatchProviderRegistry(vault).provider(account)
            val download = provider.download(account, book.id)
            val directory = store.directory(key)
            val tracks = download.files.mapIndexed { index, track ->
                coroutineContext.ensureActive()
                val trackKey = storageKey("${track.url}/${track.startMs}/${track.durationMs}")
                val file = File(directory, "$trackKey.audio")
                val part = File(directory, "$trackKey.part")
                val tag = File(directory, "$trackKey.etag")
                if (!file.exists()) {
                    val etag = tag.takeIf { it.exists() }?.readText()
                    val offset = if (etag != null) part.length() else 0L
                    provider.audio(account, track.url, offset, etag).use { response ->
                        if (response.code != 200 && response.code != 206) throw WatchRequestException("Audio download failed (${response.code}).")
                        val append = response.code == 206
                        if (append && (offset == 0L || response.header("Content-Range")?.startsWith("bytes $offset-") != true)) throw IOException("Invalid partial response")
                        val body = response.body ?: throw IOException("Empty audio response")
                        val expected = body.contentLength()
                        val storage = applicationContext.getSystemService(android.os.storage.StorageManager::class.java)
                        if (expected > 0 && storage.getAllocatableBytes(storage.getUuidForPath(directory)) < expected + 20 * 1024 * 1024) throw WatchRequestException("Not enough watch storage.")
                        response.header("ETag")?.let(tag::writeText) ?: tag.delete()
                        FileOutputStream(part, append).use { output ->
                            body.byteStream().use { input ->
                                val buffer = ByteArray(64 * 1024)
                                var copied = 0L
                                var lastUpdate = 0L
                                while (true) {
                                    coroutineContext.ensureActive()
                                    val read = input.read(buffer)
                                    if (read < 0) break
                                    output.write(buffer, 0, read)
                                    copied += read
                                    if (System.currentTimeMillis() - lastUpdate > 1000) {
                                        lastUpdate = System.currentTimeMillis()
                                        setProgress(workDataOf("track" to index + 1, "total" to download.files.size, "bytes" to copied + offset))
                                    }
                                }
                                if (copied == 0L || (expected >= 0 && copied != expected)) throw IOException("Incomplete audio response")
                            }
                            output.fd.sync()
                        }
                        if (!part.renameTo(file)) throw IOException("Could not save audio")
                        tag.delete()
                    }
                }
                WatchTrack(file.name, track.startMs, track.durationMs)
            }
            coroutineContext.ensureActive()
            store.saveBook(download.book.copy(tracks = tracks, downloaded = true))
            WatchProgressSyncWorker.enqueue(applicationContext, key)
            Result.success()
        } catch (error: CancellationException) {
            throw error
        } catch (error: WatchRequestException) {
            Result.failure(workDataOf("error" to error.message))
        } catch (error: IOException) {
            if (runAttemptCount < 3) Result.retry() else Result.failure(workDataOf("error" to "Download interrupted. Tap resume to try again."))
        } catch (_: Exception) {
            Result.failure(workDataOf("error" to "The server returned an unreadable book response."))
        }
    }

    }

    private fun foreground(title: String): ForegroundInfo {
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("watch-downloads", "Book downloads", NotificationManager.IMPORTANCE_LOW))
        val notification = NotificationCompat.Builder(applicationContext, "watch-downloads")
            .setSmallIcon(R.drawable.ic_launcher).setContentTitle(title).setContentText("Downloading to watch")
            .setOngoing(true).addAction(0, "Pause", WorkManager.getInstance(applicationContext).createCancelPendingIntent(id)).build()
        return ForegroundInfo(id.hashCode(), notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    }

    companion object {
        private val downloadLock = Mutex()
        fun enqueue(context: Context, key: String) {
            val request = OneTimeWorkRequestBuilder<WatchDownloadWorker>().setInputData(workDataOf("key" to key))
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.UNMETERED).setRequiresStorageNotLow(true).build())
                .addTag("watch-download").build()
            WorkManager.getInstance(context).enqueueUniqueWork("watch-download-$key", ExistingWorkPolicy.KEEP, request)
        }
    }
}
