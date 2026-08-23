package com.enve.app.data.offline

import android.content.Context
import android.net.Uri
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.enve.app.playback.AudiobookDownloadWorker
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.NetworkErrorMapper
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OfflineDownloadManager @Inject constructor(
    @ApplicationContext private val context: Context,
    private val resolvers: Map<BookSource, @JvmSuppressWildcards AudiobookTrackResolver>,
    private val storage: OfflineAudioStorage,
    private val okHttpClient: OkHttpClient,
    private val bookCacheDao: BookCacheDao,
) {
    private val workManager get() = WorkManager.getInstance(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val cancelSignals = ConcurrentHashMap<String, AtomicBoolean>()

    private val _progressByBookId = MutableStateFlow<Map<String, OfflineDownloadProgress>>(emptyMap())
    val progressByBookId: StateFlow<Map<String, OfflineDownloadProgress>> = _progressByBookId.asStateFlow()

    private val _downloadedBookIds = MutableStateFlow(storage.listManifests().map { it.bookId }.toSet())
    val downloadedBookIds: StateFlow<Set<String>> = _downloadedBookIds.asStateFlow()

    fun isDownloaded(bookId: String): Boolean = storage.isDownloaded(bookId)

    fun supportsAudiobookDownload(source: BookSource): Boolean = source in resolvers

    fun getManifest(bookId: String): OfflineAudioManifest? = storage.getManifest(bookId)

    fun listDownloadedManifests(): List<OfflineAudioManifest> = storage.listManifests()

    fun localCoverUri(bookId: String): String? {
        val file = storage.coverFile(bookId)
        return if (file.exists() && file.length() > 0L) Uri.fromFile(file).toString() else null
    }

    suspend fun ensureCoverCached(book: Book) {
        if (!isDownloaded(book.id)) return
        if (localCoverUri(book.id) != null) return
        kotlinx.coroutines.withContext(Dispatchers.IO) { downloadCover(book) }
    }

    fun localTracks(bookId: String): List<OfflineTrackInfo>? {
        val manifest = storage.getManifest(bookId) ?: return null
        if (manifest.tracks.isEmpty()) return null
        return manifest.tracks.mapNotNull { track ->
            val file = storage.absolutePath(track.relativePath)
            if (!file.exists()) return@mapNotNull null
            OfflineTrackInfo(
                uri = Uri.fromFile(file).toString(),
                title = track.title,
                durationMs = track.durationMs,
            )
        }.takeIf { it.isNotEmpty() }
    }

    fun startAudiobookDownload(book: Book, allowCellular: Boolean = false) {
        if (book.source !in resolvers.keys) {
            _progressByBookId.update {
                it + (
                    book.id to OfflineDownloadProgress(
                        bookId = book.id,
                        title = book.title,
                        status = OfflineDownloadStatus.FAILED,
                        progress = 0f,
                        downloadedBytes = 0,
                        totalBytes = 0,
                        completedTracks = 0,
                        totalTracks = 0,
                        errorMessage = "Offline downloads are not supported for ${book.source.displayName} yet.",
                    )
                )
            }
            return
        }

        if (_progressByBookId.value[book.id]?.status == OfflineDownloadStatus.DOWNLOADING) return
        if (storage.isDownloaded(book.id)) {
            _downloadedBookIds.update { it + book.id }
            _progressByBookId.update {
                it + (
                    book.id to OfflineDownloadProgress(
                        bookId = book.id,
                        title = book.title,
                        status = OfflineDownloadStatus.COMPLETED,
                        progress = 1f,
                        downloadedBytes = 0,
                        totalBytes = 0,
                        completedTracks = 1,
                        totalTracks = 1,
                    )
                )
            }
            return
        }

        storage.savePendingRequest(book)

        _progressByBookId.update {
            it + (
                book.id to OfflineDownloadProgress(
                    bookId = book.id,
                    title = book.title,
                    status = OfflineDownloadStatus.QUEUED,
                    progress = 0f,
                    downloadedBytes = 0,
                    totalBytes = 0,
                    completedTracks = 0,
                    totalTracks = 0,
                )
            )
        }

        val constraints = Constraints.Builder()
            .setRequiredNetworkType(if (allowCellular) NetworkType.CONNECTED else NetworkType.UNMETERED)
            .build()

        enqueueDownloadWork(book.id, constraints, ExistingWorkPolicy.KEEP)
    }

    fun retryDownload(bookId: String, allowCellular: Boolean = false): Boolean {
        val book = storage.getPendingRequest(bookId) ?: return false
        _progressByBookId.update {
            it + (
                book.id to OfflineDownloadProgress(
                    bookId = book.id,
                    title = book.title,
                    status = OfflineDownloadStatus.QUEUED,
                    progress = 0f,
                    downloadedBytes = 0,
                    totalBytes = 0,
                    completedTracks = 0,
                    totalTracks = 0,
                )
            )
        }
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(if (allowCellular) NetworkType.CONNECTED else NetworkType.UNMETERED)
            .build()
        enqueueDownloadWork(book.id, constraints, ExistingWorkPolicy.REPLACE)
        return true
    }

    suspend fun runDownload(book: Book): Boolean {
        if (storage.isDownloaded(book.id)) {
            storage.clearPendingRequest(book.id)
            return true
        }
        val cancelSignal = AtomicBoolean(false)
        cancelSignals[book.id] = cancelSignal
        return try {
            downloadBook(book, cancelSignal)
            storage.clearPendingRequest(book.id)
            true
        } catch (error: Throwable) {
            if (error is CancellationException || cancelSignal.get()) {
                _progressByBookId.update { current ->
                    val existing = current[book.id]
                    current + (
                        book.id to OfflineDownloadProgress(
                            bookId = book.id,
                            title = book.title,
                            status = OfflineDownloadStatus.CANCELLED,
                            progress = existing?.progress ?: 0f,
                            downloadedBytes = existing?.downloadedBytes ?: 0,
                            totalBytes = existing?.totalBytes ?: 0,
                            completedTracks = existing?.completedTracks ?: 0,
                            totalTracks = existing?.totalTracks ?: 0,
                            errorMessage = null,
                        )
                    )
                }
                storage.clearPendingRequest(book.id)
                throw error
            }
            _progressByBookId.update { current ->
                val existing = current[book.id]
                current + (
                    book.id to OfflineDownloadProgress(
                        bookId = book.id,
                        title = book.title,
                        status = OfflineDownloadStatus.FAILED,
                        progress = existing?.progress ?: 0f,
                        downloadedBytes = existing?.downloadedBytes ?: 0,
                        totalBytes = existing?.totalBytes ?: 0,
                        completedTracks = existing?.completedTracks ?: 0,
                        totalTracks = existing?.totalTracks ?: 0,
                        errorMessage = NetworkErrorMapper.mapForUser(error.message),
                    )
                )
            }
            false
        } finally {
            cancelSignals.remove(book.id)
        }
    }

    fun cancelDownload(bookId: String) {
        cancelSignals[bookId]?.set(true)
        workManager.cancelUniqueWork(workName(bookId))
        storage.clearPendingRequest(bookId)
    }

    fun removeDownload(bookId: String) {
        cancelDownload(bookId)
        storage.removeDownload(bookId)
        scope.launch {
            bookCacheDao.updateDownloadedStatusById(bookId, downloaded = false, nowMs = System.currentTimeMillis())
        }
        _downloadedBookIds.update { it - bookId }
        _progressByBookId.update { it - bookId }
    }

    private fun enqueueDownloadWork(
        bookId: String,
        constraints: Constraints,
        policy: ExistingWorkPolicy,
    ) {
        val request = OneTimeWorkRequestBuilder<AudiobookDownloadWorker>()
            .setConstraints(constraints)
            .setInputData(Data.Builder().putString(AudiobookDownloadWorker.KEY_BOOK_ID, bookId).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(WORK_TAG)
            .build()
        workManager.enqueueUniqueWork(workName(bookId), policy, request)
    }

    private suspend fun downloadBook(book: Book, cancelSignal: AtomicBoolean) {
        val resolver = resolvers[book.source]
            ?: throw IllegalStateException("No resolver registered for ${book.source.displayName}")
        val plannedTracks = resolver.resolveTracks(book).getOrThrow()
        if (plannedTracks.isEmpty()) throw IllegalStateException("No tracks resolved for ${book.title}")

        if (cancelSignal.get()) throw CancellationException("Cancelled")

        var downloadedBytes = 0L
        var knownTotalBytes = 0L
        var completedTracks = 0
        val manifestTracks = mutableListOf<OfflineAudioTrackManifest>()

        _progressByBookId.update {
            it + (
                book.id to OfflineDownloadProgress(
                    bookId = book.id,
                    title = book.title,
                    status = OfflineDownloadStatus.DOWNLOADING,
                    progress = 0f,
                    downloadedBytes = 0,
                    totalBytes = 0,
                    completedTracks = 0,
                    totalTracks = plannedTracks.size,
                )
            )
        }

        for (track in plannedTracks) {
            if (cancelSignal.get()) throw CancellationException("Cancelled")

            val existingFinal = storage.existingTrackFinalFile(book.id, track.index)
            if (existingFinal != null) {
                downloadedBytes += existingFinal.length()
                knownTotalBytes += existingFinal.length()
                completedTracks += 1
                manifestTracks += OfflineAudioTrackManifest(
                    index = track.index,
                    title = track.title,
                    durationMs = track.durationMs,
                    relativePath = storage.relativePath(existingFinal),
                    bytes = existingFinal.length(),
                )
                continue
            }

            val tmp = storage.createTrackTempFile(book.id, track.index)
            var resumeOffset = tmp.takeIf { it.exists() }?.length()?.takeIf { it > 0L } ?: 0L
            fun requestFor(offset: Long): Request =
                Request.Builder().url(track.url).get().apply {
                    track.httpHeaders.forEach { (name, value) -> header(name, value) }
                    if (offset > 0L) header("Range", "bytes=$offset-")
                }.build()

            var response = okHttpClient.newCall(requestFor(resumeOffset)).execute()
            if (resumeOffset > 0L && response.code == 416) {
                response.close()
                tmp.delete()
                resumeOffset = 0L
                response = okHttpClient.newCall(requestFor(0L)).execute()
            }

            response.use { response ->
                if (resumeOffset > 0L && response.code == 200) {
                    tmp.delete()
                    resumeOffset = 0L
                }
                if (!response.isSuccessful) {
                    throw IllegalStateException("Track download failed with HTTP ${response.code}")
                }
                val body = response.body ?: throw IllegalStateException("Empty response body")
                val responseLength = body.contentLength().takeIf { it > 0 } ?: 0L
                val trackLength = when {
                    response.code == 206 && responseLength > 0L -> resumeOffset + responseLength
                    responseLength > 0L -> responseLength
                    else -> 0L
                }
                if (trackLength > 0) knownTotalBytes += trackLength
                var trackDownloadedBytes = resumeOffset
                downloadedBytes += resumeOffset

                val extension = extensionFor(track.url, response.header("Content-Type"))
                val final = storage.createTrackFinalFile(book.id, track.index, extension)

                if (resumeOffset == 0L && tmp.exists()) tmp.delete()
                if (final.exists()) final.delete()

                body.byteStream().use { input ->
                    FileOutputStream(tmp, resumeOffset > 0L && response.code == 206).use { output ->
                        val buffer = ByteArray(32_768)
                        var lastUpdateTime = 0L
                        while (true) {
                            if (cancelSignal.get()) throw CancellationException("Cancelled")
                            val read = input.read(buffer)
                            if (read <= 0) break
                            output.write(buffer, 0, read)
                            downloadedBytes += read
                            trackDownloadedBytes += read

                            val now = System.currentTimeMillis()
                            if (now - lastUpdateTime > 200L) {
                                lastUpdateTime = now
                                val withinTrack = if (trackLength > 0L) {
                                    (trackDownloadedBytes.toFloat() / trackLength.toFloat()).coerceIn(0f, 0.99f)
                                } else {
                                    (trackDownloadedBytes.toFloat() / (trackDownloadedBytes.toFloat() + 2_000_000f))
                                        .coerceIn(0f, 0.95f)
                                }
                                val currentProgress = (
                                    (completedTracks.toFloat() + withinTrack) /
                                        plannedTracks.size.toFloat()
                                    ).coerceIn(0f, 0.99f)
                                _progressByBookId.update { current ->
                                    val newMap = current.toMutableMap()
                                    newMap[book.id] = OfflineDownloadProgress(
                                        bookId = book.id,
                                        title = book.title,
                                        status = OfflineDownloadStatus.DOWNLOADING,
                                        progress = currentProgress,
                                        downloadedBytes = downloadedBytes,
                                        totalBytes = knownTotalBytes,
                                        completedTracks = completedTracks,
                                        totalTracks = plannedTracks.size,
                                    )
                                    newMap.toMap()
                                }
                            }
                        }
                    }
                }

                if (!tmp.renameTo(final)) {
                    tmp.copyTo(final, overwrite = true)
                    tmp.delete()
                }

                completedTracks += 1
                manifestTracks += OfflineAudioTrackManifest(
                    index = track.index,
                    title = track.title,
                    durationMs = track.durationMs,
                    relativePath = storage.relativePath(final),
                    bytes = final.length(),
                )
            }
        }

        if (cancelSignal.get()) throw CancellationException("Cancelled")

        val localCoverUri = downloadCover(book)

        storage.saveManifest(
            OfflineAudioManifest(
                bookId = book.id,
                title = book.title,
                author = book.author,
                coverUrl = localCoverUri ?: book.coverUrl,
                source = book.source.name,
                downloadedAtEpochMs = System.currentTimeMillis(),
                tracks = manifestTracks,
            )
        )

        _downloadedBookIds.update { it + book.id }
        val updatedRows = bookCacheDao.updateDownloadedStatus(
            bookId = book.id,
            connectionId = book.connectionId,
            downloaded = true,
            nowMs = System.currentTimeMillis(),
        )
        if (updatedRows == 0) {
            bookCacheDao.updateDownloadedStatusById(
                bookId = book.id,
                downloaded = true,
                nowMs = System.currentTimeMillis(),
            )
        }
        _progressByBookId.update {
            it + (
                book.id to OfflineDownloadProgress(
                    bookId = book.id,
                    title = book.title,
                    status = OfflineDownloadStatus.COMPLETED,
                    progress = 1f,
                    downloadedBytes = downloadedBytes,
                    totalBytes = knownTotalBytes,
                    completedTracks = plannedTracks.size,
                    totalTracks = plannedTracks.size,
                )
            )
        }
    }

    private fun downloadCover(book: Book): String? {
        val coverUrl = book.coverUrl?.takeIf { it.isNotBlank() } ?: return null
        return runCatching {
            val request = Request.Builder().url(coverUrl).get().build()
            okHttpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return null
                val body = response.body ?: return null
                val file = storage.coverFile(book.id)
                body.byteStream().use { input ->
                    file.outputStream().use { output -> input.copyTo(output) }
                }
                if (file.length() == 0L) {
                    file.delete()
                    null
                } else {
                    Uri.fromFile(file).toString()
                }
            }
        }.getOrNull()
    }

    private fun extensionFor(url: String, contentType: String?): String {
        val fromContentType = when {
            contentType.isNullOrBlank() -> null
            contentType.contains("mpeg", ignoreCase = true) -> "mp3"
            contentType.contains("mp4", ignoreCase = true) -> "m4a"
            contentType.contains("aac", ignoreCase = true) -> "aac"
            contentType.contains("ogg", ignoreCase = true) -> "ogg"
            contentType.contains("flac", ignoreCase = true) -> "flac"
            else -> null
        }
        if (!fromContentType.isNullOrBlank()) return fromContentType

        val raw = url.substringAfterLast('/', "").substringBefore('?')
        val ext = raw.substringAfterLast('.', "").lowercase()
        if (ext.length in 2..5 && ext.all { it.isLetterOrDigit() }) return ext
        return "bin"
    }

    companion object {
        private const val WORK_TAG = "audiobook-download"
        fun workName(bookId: String): String = "audiobook-download:$bookId"
    }
}
