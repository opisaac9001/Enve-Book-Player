package com.enve.app.data.offline

import com.enve.core.di.ApplicationScope
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
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
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.NetworkErrorMapper
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
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
    @ApplicationScope parentScope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
) {
    private val workManager get() = WorkManager.getInstance(context)
    private val connectivityManager get() = context.getSystemService(ConnectivityManager::class.java)
    private val scope = CoroutineScope(SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.IO)
    private val admissionLock = Any()
    private var acceptingDownloads = true
    private val activeDownloads = mutableSetOf<Job>()
    private val cancelSignals = ConcurrentHashMap<String, AtomicBoolean>()

    private val _progressByBookId = MutableStateFlow<Map<String, OfflineDownloadProgress>>(emptyMap())
    val progressByBookId: StateFlow<Map<String, OfflineDownloadProgress>> = _progressByBookId.asStateFlow()

    private val _downloadedBookIds = MutableStateFlow(storage.listManifests().map { it.bookId }.toSet())
    val downloadedBookIds: StateFlow<Set<String>> = _downloadedBookIds.asStateFlow()

    fun isDownloaded(bookId: String): Boolean = storage.isDownloaded(bookId)

    fun supportsAudiobookDownload(source: BookSource): Boolean = source in resolvers

    fun getManifest(bookId: String): OfflineAudioManifest? = storage.getManifest(bookId)

    fun listDownloadedManifests(): List<OfflineAudioManifest> = storage.listManifests()

    fun sharedStorageBytes(): Long = storage.sharedStorageBytes()

    fun localCoverUri(bookId: String): String? {
        val file = storage.coverFile(bookId)
        return if (file.exists() && file.length() > 0L) Uri.fromFile(file).toString() else null
    }

    suspend fun ensureCoverCached(book: Book) {
        if (!isDownloaded(book.id)) return
        if (localCoverUri(book.id) != null) return
        kotlinx.coroutines.withContext(Dispatchers.IO) { okHttpClient.withDownloadCalls { downloadCover(book, it) } }
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
        synchronized(admissionLock) {
            check(acceptingDownloads) { "Downloads are paused for this profile." }
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

            val requireWifi = !allowCellular && isVpnOverWifi()
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(networkType(allowCellular, requireWifi))
                .build()

            enqueueDownloadWork(book.id, constraints, ExistingWorkPolicy.REPLACE, requireWifi)
        }
    }

    fun retryDownload(bookId: String, allowCellular: Boolean = false): Boolean = synchronized(admissionLock) {
        check(acceptingDownloads) { "Downloads are paused for this profile." }
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
        val requireWifi = !allowCellular && isVpnOverWifi()
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(networkType(allowCellular, requireWifi))
            .build()
        enqueueDownloadWork(book.id, constraints, ExistingWorkPolicy.REPLACE, requireWifi)
        return true
    }

    suspend fun pauseAllAndAwait() {
        val jobs = synchronized(admissionLock) {
            acceptingDownloads = false
            activeDownloads.toList()
        }
        val tag = if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) WORK_TAG else profileWorkTag
        runInterruptible(Dispatchers.IO) { workManager.cancelAllWorkByTag(tag).result.get() }
        jobs.forEach { it.cancelAndJoin() }
    }

    fun resumeDownloads() {
        synchronized(admissionLock) { acceptingDownloads = true }
        scope.launch {
            storage.listPendingRequests().forEach { book ->
                synchronized(admissionLock) {
                    if (acceptingDownloads) {
                        _progressByBookId.update { it - book.id }
                        startAudiobookDownload(book)
                    }
                }
            }
        }
    }

    fun refreshCompletedDownloads() {
        _downloadedBookIds.value = storage.listManifests().map { it.bookId }.toSet()
    }

    suspend fun runDownload(book: Book, requireWifi: Boolean = false): Boolean = coroutineScope {
        val job = checkNotNull(currentCoroutineContext()[Job])
        synchronized(admissionLock) {
            check(acceptingDownloads) { "Downloads are paused for this profile." }
            activeDownloads += job
        }
        try {
            runCapturedDownload(book, requireWifi)
        } finally {
            synchronized(admissionLock) { activeDownloads -= job }
        }
    }

    private suspend fun runCapturedDownload(book: Book, requireWifi: Boolean = false): Boolean {
        if (storage.isDownloaded(book.id)) {
            storage.clearPendingRequest(book.id)
            return true
        }
        val cancelSignal = AtomicBoolean(false)
        cancelSignals[book.id] = cancelSignal
        return try {
            downloadBook(book, cancelSignal, requireWifi)
            storage.clearPendingRequest(book.id)
            true
        } catch (error: Throwable) {
            currentCoroutineContext().ensureActive()
            if ((error is CancellationException && !cancelSignal.get()) || error is WifiUnavailableException) {
                _progressByBookId.update { current ->
                    val existing = current[book.id]
                    val queued = existing?.copy(status = OfflineDownloadStatus.QUEUED) ?: OfflineDownloadProgress(
                        bookId = book.id,
                        title = book.title,
                        status = OfflineDownloadStatus.QUEUED,
                        progress = 0f,
                        downloadedBytes = 0,
                        totalBytes = 0,
                        completedTracks = 0,
                        totalTracks = 0,
                    )
                    current + (book.id to queued)
                }
                if (error is CancellationException) throw error
                return false
            }
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
            cancelSignals.remove(book.id, cancelSignal)
        }
    }

    fun cancelDownload(bookId: String) {
        cancelSignals[bookId]?.set(true)
        workManager.cancelUniqueWork(scopedWorkName(bookId))
        storage.clearPendingRequest(bookId)
        _progressByBookId.update { it - bookId }
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
        requireWifi: Boolean,
    ) {
        val request = OneTimeWorkRequestBuilder<AudiobookDownloadWorker>()
            .setConstraints(constraints)
            .setInputData(
                Data.Builder()
                    .putString(AudiobookDownloadWorker.KEY_BOOK_ID, bookId)
                    .putString(AudiobookDownloadWorker.KEY_PROFILE_ID, locations.profileId)
                    .putBoolean(AudiobookDownloadWorker.KEY_REQUIRE_WIFI, requireWifi)
                    .build()
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(profileWorkTag)
            .apply { if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) addTag(WORK_TAG) }
            .build()
        workManager.enqueueUniqueWork(scopedWorkName(bookId), policy, request)
    }

    private suspend fun downloadBook(book: Book, cancelSignal: AtomicBoolean, requireWifi: Boolean) = okHttpClient.withDownloadCalls { calls ->
        ensureWifiAvailable(requireWifi)
        val resolver = resolvers[book.source]
            ?: throw IllegalStateException("No resolver registered for ${book.source.displayName}")
        val plannedTracks = resolver.resolveTracks(book).getOrThrow()
        if (plannedTracks.isEmpty()) throw IllegalStateException("No tracks resolved for ${book.title}")

        currentCoroutineContext().ensureActive()
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
            currentCoroutineContext().ensureActive()
            if (cancelSignal.get()) throw CancellationException("Cancelled")
            ensureWifiAvailable(requireWifi)

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

            var response = calls.execute(requestFor(resumeOffset))
            if (resumeOffset > 0L && response.code == 416) {
                response.close()
                tmp.delete()
                resumeOffset = 0L
                response = calls.execute(requestFor(0L))
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
                if (final.exists()) check(final.delete())

                body.byteStream().use { input ->
                    FileOutputStream(tmp, resumeOffset > 0L && response.code == 206).use { output ->
                        val buffer = ByteArray(32_768)
                        var lastUpdateTime = 0L
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            if (cancelSignal.get()) throw CancellationException("Cancelled")
                            ensureWifiAvailable(requireWifi)
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

                currentCoroutineContext().ensureActive()
                if (!tmp.renameTo(final)) {
                    tmp.copyTo(final)
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

        currentCoroutineContext().ensureActive()
        if (cancelSignal.get()) throw CancellationException("Cancelled")
        ensureWifiAvailable(requireWifi)

        val localCoverUri = downloadCover(book, calls)
        currentCoroutineContext().ensureActive()

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

    private fun networkType(allowCellular: Boolean, requireWifi: Boolean): NetworkType =
        if (allowCellular || requireWifi) NetworkType.NOT_REQUIRED else NetworkType.UNMETERED

    private fun isVpnOverWifi(): Boolean {
        val active = connectivityManager.getNetworkCapabilities(connectivityManager.activeNetwork)
        return active?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true && wifiAvailable()
    }

    private fun ensureWifiAvailable(required: Boolean) {
        if (required && !wifiAvailable()) throw WifiUnavailableException()
    }

    @Suppress("DEPRECATION")
    private fun wifiAvailable(): Boolean = connectivityManager.allNetworks.any { network ->
        connectivityManager.getNetworkCapabilities(network)
            ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }

    private class WifiUnavailableException : RuntimeException()

    private suspend fun downloadCover(book: Book, calls: DownloadCalls): String? {
        val coverUrl = book.coverUrl?.takeIf { it.isNotBlank() } ?: return null
        return runCatching {
            val request = Request.Builder().url(coverUrl).get().build()
            calls.execute(request).use { response ->
                if (!response.isSuccessful) return null
                val body = response.body ?: return null
                val file = storage.coverFile(book.id)
                if (java.nio.file.Files.isSymbolicLink(file.toPath())) check(file.delete())
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
        }.getOrElse { error ->
            if (error is CancellationException) throw error
            currentCoroutineContext().ensureActive()
            null
        }
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

    private val profileWorkTag: String get() = "$WORK_TAG:profile:${locations.profileId}"

    private fun scopedWorkName(bookId: String): String =
        if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) workName(bookId)
        else "profile:${locations.profileId}:${workName(bookId)}"

    companion object {
        private const val WORK_TAG = "audiobook-download"
        fun workName(bookId: String): String = "audiobook-download:$bookId"
    }
}
