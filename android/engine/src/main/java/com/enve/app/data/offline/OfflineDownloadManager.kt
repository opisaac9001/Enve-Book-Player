package com.enve.app.data.offline

import com.enve.core.di.ApplicationScope
import android.content.Context
import android.media.MediaMetadataRetriever
import android.util.Log
import com.enve.core.data.util.runSuspendCatching
import java.io.File
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
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
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
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
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
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

enum class DownloadRunOutcome { COMPLETED, RETRY, FAILED }

internal class TrackDownloadHttpException(val code: Int) : IllegalStateException("Track download failed with HTTP $code")

internal class TrackDownloadIntegrityException(message: String) : IOException(message)

internal class UnsupportedDownloadException(message: String) : IllegalStateException(message)

internal fun isRetryableDownloadFailure(error: Throwable): Boolean = when (error) {
    is TrackDownloadHttpException -> error.code == 408 || error.code == 429 || error.code >= 500
    is UnsupportedDownloadException -> false
    else -> true
}

internal fun strongResumeValidator(etag: String?, lastModified: String?): String? =
    etag?.trim()?.takeIf { it.isNotEmpty() && !it.startsWith("W/") }
        ?: lastModified?.trim()?.takeIf { it.isNotEmpty() }

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
    private val transferLocks = DownloadTransferLocks()

    private val _progressByDownloadKey = MutableStateFlow<Map<String, OfflineDownloadProgress>>(emptyMap())
    val progressByDownloadKey: StateFlow<Map<String, OfflineDownloadProgress>> = _progressByDownloadKey.asStateFlow()

    private val _downloadedKeys = MutableStateFlow(completedManifests().map { it.downloadKey }.toSet())
    val downloadedKeys: StateFlow<Set<String>> = _downloadedKeys.asStateFlow()

    init {
        scope.launch { registerRecoveredDownloads() }
    }

    private suspend fun registerRecoveredDownloads() {
        completedManifests().filter { isRecoveredLocalBookId(it.bookId) }.forEach { manifest ->
            runSuspendCatching {
                val book = Book(
                    id = manifest.bookId,
                    title = manifest.title,
                    author = manifest.author,
                    coverUrl = localCoverUri(manifest.downloadKey) ?: manifest.coverUrl,
                    duration = manifest.tracks.sumOf { it.durationMs } / 1_000L,
                    source = BookSource.LOCAL,
                    mediaType = AppMediaType.AUDIOBOOK,
                    hasAudio = true,
                    isDownloaded = true,
                )
                bookCacheDao.insertIfAbsent(book.toCachedBook())
            }.onFailure { Log.w("OfflineDownloadManager", "Recovered download ${manifest.downloadKey} was not registered", it) }
        }
    }

    fun recoverQueuedDownloads() = synchronized(admissionLock) {
        if (acceptingDownloads) storage.listPendingRequests().forEach { book ->
            val key = book.offlineDownloadKey
            _progressByDownloadKey.update {
                if (key in it) it else it + (
                    key to OfflineDownloadProgress(
                        downloadKey = key,
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
            val requireWifi = isVpnOverWifi()
            val constraints = Constraints.Builder().setRequiredNetworkType(networkType(false, requireWifi)).build()
            enqueueDownloadWork(key, constraints, ExistingWorkPolicy.KEEP, requireWifi)
        }
    }

    fun isDownloaded(key: String): Boolean = storage.isDownloaded(key)

    fun supportsAudiobookDownload(source: BookSource): Boolean = source in resolvers

    fun getManifest(key: String): OfflineAudioManifest? = storage.getManifest(key)

    fun listDownloadedManifests(): List<OfflineAudioManifest> = completedManifests()

    private fun completedManifests(): List<OfflineAudioManifest> =
        storage.listManifests().filter { storage.isDownloaded(it.downloadKey) }

    fun sharedStorageBytes(): Long = storage.sharedStorageBytes()

    fun localCoverUri(key: String): String? {
        val file = storage.coverFile(key)
        return if (file.exists() && file.length() > 0L) Uri.fromFile(file).toString() else null
    }

    suspend fun ensureCoverCached(book: Book) {
        val key = book.offlineDownloadKey
        if (!isDownloaded(key)) return
        if (localCoverUri(key) != null) return
        kotlinx.coroutines.withContext(Dispatchers.IO) { okHttpClient.withDownloadCalls { downloadCover(book, it) } }
    }

    fun localTracks(key: String): List<OfflineTrackInfo>? {
        if (!storage.isDownloaded(key)) return null
        val manifest = storage.getManifest(key) ?: return null
        return manifest.tracks.map { track ->
            OfflineTrackInfo(
                uri = Uri.fromFile(storage.absolutePath(track.relativePath)).toString(),
                title = track.title,
                durationMs = track.durationMs,
            )
        }
    }

    fun startAudiobookDownload(book: Book, allowCellular: Boolean = false) {
        val key = book.offlineDownloadKey
        synchronized(admissionLock) {
            check(acceptingDownloads) { "Downloads are paused for this profile." }
            if (book.source !in resolvers.keys) {
                _progressByDownloadKey.update {
                    it + (
                        key to OfflineDownloadProgress(
                            downloadKey = key,
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

            if (_progressByDownloadKey.value[key]?.status == OfflineDownloadStatus.DOWNLOADING) return
            if (storage.isDownloaded(key)) {
                _downloadedKeys.update { it + key }
                _progressByDownloadKey.update {
                    it + (
                        key to OfflineDownloadProgress(
                            downloadKey = key,
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

            _progressByDownloadKey.update {
                it + (
                    key to OfflineDownloadProgress(
                        downloadKey = key,
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

            enqueueDownloadWork(key, constraints, ExistingWorkPolicy.REPLACE, requireWifi)
        }
    }

    fun retryDownload(key: String, allowCellular: Boolean = false): Boolean = synchronized(admissionLock) {
        check(acceptingDownloads) { "Downloads are paused for this profile." }
        val book = storage.getPendingRequest(key) ?: return false
        _progressByDownloadKey.update {
            it + (
                key to OfflineDownloadProgress(
                    downloadKey = key,
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
        enqueueDownloadWork(key, constraints, ExistingWorkPolicy.REPLACE, requireWifi)
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
                        _progressByDownloadKey.update { it - book.offlineDownloadKey }
                        startAudiobookDownload(book)
                    }
                }
            }
        }
    }

    fun refreshCompletedDownloads() {
        _downloadedKeys.value = completedManifests().map { it.downloadKey }.toSet()
    }

    suspend fun runDownload(book: Book, requireWifi: Boolean = false, finalAttempt: Boolean = true): DownloadRunOutcome = coroutineScope {
        val job = checkNotNull(currentCoroutineContext()[Job])
        synchronized(admissionLock) {
            check(acceptingDownloads) { "Downloads are paused for this profile." }
            activeDownloads += job
        }
        try {
            transferLocks.withKey(book.offlineDownloadKey) { runCapturedDownload(book, requireWifi, finalAttempt) }
        } finally {
            synchronized(admissionLock) { activeDownloads -= job }
        }
    }

    private suspend fun runCapturedDownload(book: Book, requireWifi: Boolean, finalAttempt: Boolean): DownloadRunOutcome {
        val key = book.offlineDownloadKey
        if (storage.isDownloaded(key)) {
            storage.clearPendingRequest(key)
            return DownloadRunOutcome.COMPLETED
        }
        val cancelSignal = AtomicBoolean(false)
        synchronized(admissionLock) { cancelSignals[key] = cancelSignal }
        return try {
            currentCoroutineContext().ensureActive()
            downloadBook(book, cancelSignal, requireWifi)
            synchronized(admissionLock) {
                if (!cancelSignal.get()) storage.clearPendingRequest(key)
            }
            DownloadRunOutcome.COMPLETED
        } catch (error: Throwable) {
            if (cancelSignal.get()) {
                synchronized(admissionLock) {
                    if (storage.getPendingRequest(key) == null) _progressByDownloadKey.update { it - key }
                    storage.discardPartialDownload(key)
                }
                throw error
            }
            if (!currentCoroutineContext().isActive) {
                _progressByDownloadKey.update { current ->
                    current[key]?.let { current + (key to it.copy(status = OfflineDownloadStatus.QUEUED)) } ?: current
                }
            }
            currentCoroutineContext().ensureActive()
            if (error is CancellationException || error is WifiUnavailableException) {
                _progressByDownloadKey.update { current ->
                    val existing = current[key]
                    val queued = existing?.copy(status = OfflineDownloadStatus.QUEUED) ?: OfflineDownloadProgress(
                        downloadKey = key,
                        bookId = book.id,
                        title = book.title,
                        status = OfflineDownloadStatus.QUEUED,
                        progress = 0f,
                        downloadedBytes = 0,
                        totalBytes = 0,
                        completedTracks = 0,
                        totalTracks = 0,
                    )
                    current + (key to queued)
                }
                if (error is CancellationException) throw error
                return DownloadRunOutcome.RETRY
            }
            val retry = !finalAttempt && isRetryableDownloadFailure(error)
            _progressByDownloadKey.update { current ->
                val existing = current[key]
                current + (
                    key to OfflineDownloadProgress(
                        downloadKey = key,
                        bookId = book.id,
                        title = book.title,
                        status = if (retry) OfflineDownloadStatus.QUEUED else OfflineDownloadStatus.FAILED,
                        progress = existing?.progress ?: 0f,
                        downloadedBytes = existing?.downloadedBytes ?: 0,
                        totalBytes = existing?.totalBytes ?: 0,
                        completedTracks = existing?.completedTracks ?: 0,
                        totalTracks = existing?.totalTracks ?: 0,
                        errorMessage = NetworkErrorMapper.mapForUser(error.message),
                    )
                )
            }
            if (retry) DownloadRunOutcome.RETRY else DownloadRunOutcome.FAILED
        } finally {
            cancelSignals.remove(key, cancelSignal)
        }
    }

    fun cancelDownload(key: String) = synchronized(admissionLock) {
        val activeRun = cancelSignals[key]?.also { it.set(true) }
        workManager.cancelUniqueWork(scopedWorkName(key))
        storage.clearPendingRequest(key)
        _progressByDownloadKey.update { it - key }
        if (activeRun == null) storage.discardPartialDownload(key)
    }

    fun removeDownload(key: String) = synchronized(admissionLock) {
        val manifest = storage.getManifest(key)
        cancelDownload(key)
        storage.removeDownload(key)
        if (manifest != null) scope.launch {
            bookCacheDao.updateDownloadedStatus(manifest.bookId, manifest.connectionId, downloaded = false, nowMs = System.currentTimeMillis())
        }
        _downloadedKeys.update { it - key }
        _progressByDownloadKey.update { it - key }
    }

    private fun enqueueDownloadWork(
        key: String,
        constraints: Constraints,
        policy: ExistingWorkPolicy,
        requireWifi: Boolean,
    ) {
        val request = OneTimeWorkRequestBuilder<AudiobookDownloadWorker>()
            .setConstraints(constraints)
            .setInputData(
                Data.Builder()
                    .putString(AudiobookDownloadWorker.KEY_DOWNLOAD_KEY, key)
                    .putString(AudiobookDownloadWorker.KEY_PROFILE_ID, locations.profileId)
                    .putBoolean(AudiobookDownloadWorker.KEY_REQUIRE_WIFI, requireWifi)
                    .build()
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(profileWorkTag)
            .apply { if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) addTag(WORK_TAG) }
            .build()
        workManager.enqueueUniqueWork(scopedWorkName(key), policy, request)
    }

    private fun downloadedTrackDuration(source: BookSource, durationMs: Long, file: File): Long {
        if (source != BookSource.TORBOX || durationMs > 0) return durationMs
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.absolutePath)
            val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
            check(duration != null && duration > 0) { "The downloaded TorBox audio file has no readable duration." }
            return duration
        } finally {
            retriever.release()
        }
    }

    private suspend fun downloadBook(book: Book, cancelSignal: AtomicBoolean, requireWifi: Boolean) = okHttpClient.withDownloadCalls { calls ->
        val key = book.offlineDownloadKey
        fun updateProgress(update: (Map<String, OfflineDownloadProgress>) -> Map<String, OfflineDownloadProgress>) {
            synchronized(admissionLock) {
                if (cancelSignal.get()) throw CancellationException("Cancelled")
                _progressByDownloadKey.update(update)
            }
        }
        ensureWifiAvailable(requireWifi)
        val resolver = resolvers[book.source]
            ?: throw UnsupportedDownloadException("No resolver registered for ${book.source.displayName}")
        val plannedTracks = resolver.resolveTracks(book).getOrThrow()
        if (plannedTracks.isEmpty()) throw UnsupportedDownloadException("No tracks resolved for ${book.title}")

        currentCoroutineContext().ensureActive()
        if (cancelSignal.get()) throw CancellationException("Cancelled")

        var downloadedBytes = 0L
        var knownTotalBytes = 0L
        var completedTracks = 0
        val manifestTracks = mutableListOf<OfflineAudioTrackManifest>()

        updateProgress {
            it + (
                key to OfflineDownloadProgress(
                    downloadKey = key,
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

            val assetFile = storage.trackAssetFile(key, track.index)
            val existingFinal = storage.existingTrackFinalFile(key, track.index)?.let { file ->
                val storedAssetId = assetFile.takeIf { it.isFile }?.readText()
                val replacedOnServer = track.assetId != null && storedAssetId != null && storedAssetId != track.assetId
                if (replacedOnServer || (track.sizeBytes > 0L && file.length() != track.sizeBytes)) {
                    check(file.delete())
                    null
                } else {
                    file
                }
            }
            if (existingFinal != null) {
                downloadedBytes += existingFinal.length()
                knownTotalBytes += existingFinal.length()
                completedTracks += 1
                manifestTracks += OfflineAudioTrackManifest(
                    index = track.index,
                    title = track.title,
                    durationMs = downloadedTrackDuration(book.source, track.durationMs, existingFinal),
                    relativePath = storage.relativePath(existingFinal),
                    bytes = existingFinal.length(),
                )
                continue
            }

            val tmp = storage.createTrackTempFile(key, track.index)
            val validatorFile = storage.trackResumeValidatorFile(key, track.index)
            val storedValidator = validatorFile.takeIf { it.isFile }?.readText()?.takeIf { it.isNotBlank() }
            var resumeOffset = tmp.takeIf { it.exists() }?.length()?.takeIf { it > 0L } ?: 0L
            if (resumeOffset > 0L && storedValidator == null) {
                check(tmp.delete())
                resumeOffset = 0L
            }
            fun requestFor(offset: Long): Request =
                Request.Builder().url(track.url).get().apply {
                    track.httpHeaders.forEach { (name, value) -> header(name, value) }
                    if (offset > 0L) {
                        header("Range", "bytes=$offset-")
                        storedValidator?.let { header("If-Range", it) }
                    }
                }.build()
            fun discardPartial(message: String): Nothing {
                tmp.delete()
                validatorFile.delete()
                throw TrackDownloadIntegrityException(message)
            }

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
                if (!response.isSuccessful) throw TrackDownloadHttpException(response.code)
                val body = response.body ?: throw IllegalStateException("Empty response body")
                val validator = strongResumeValidator(response.header("ETag"), response.header("Last-Modified"))
                val serverLength = if (response.code == 206) {
                    try {
                        completeBookRangeLength(
                            response.header("Content-Range"), resumeOffset, body.contentLength(), storedValidator, validator,
                        )
                    } catch (e: IllegalStateException) {
                        discardPartial(e.message ?: "Invalid track byte range")
                    }
                } else body.contentLength().coerceAtLeast(0L)
                if (track.sizeBytes > 0L && serverLength > 0L && serverLength != track.sizeBytes) {
                    discardPartial("Track size from the server does not match the audiobook manifest")
                }
                val trackLength = serverLength.takeIf { it > 0L } ?: track.sizeBytes.coerceAtLeast(0L)
                if (resumeOffset == 0L) {
                    if (validator != null) validatorFile.writeText(validator) else validatorFile.delete()
                }
                if (trackLength > 0) knownTotalBytes += trackLength
                var trackDownloadedBytes = resumeOffset
                downloadedBytes += resumeOffset

                val extension = extensionFor(track.url, response.header("Content-Type"))
                val final = storage.createTrackFinalFile(key, track.index, extension)

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
                                updateProgress { current ->
                                    val newMap = current.toMutableMap()
                                    newMap[key] = OfflineDownloadProgress(
                                        downloadKey = key,
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
                if (tmp.length() == 0L || (trackLength > 0L && tmp.length() != trackLength)) {
                    discardPartial("Downloaded track size does not match the server")
                }
                check(tmp.renameTo(final)) { "Could not install downloaded track" }
                validatorFile.delete()
                track.assetId?.let(assetFile::writeText) ?: assetFile.delete()

                completedTracks += 1
                manifestTracks += OfflineAudioTrackManifest(
                    index = track.index,
                    title = track.title,
                    durationMs = downloadedTrackDuration(book.source, track.durationMs, final),
                    relativePath = storage.relativePath(final),
                    bytes = trackLength.takeIf { it > 0L } ?: final.length(),
                )
            }
        }

        currentCoroutineContext().ensureActive()
        if (cancelSignal.get()) throw CancellationException("Cancelled")
        ensureWifiAvailable(requireWifi)

        val localCoverUri = downloadCover(book, calls)
        currentCoroutineContext().ensureActive()

        synchronized(admissionLock) {
            if (cancelSignal.get()) throw CancellationException("Cancelled")
            storage.saveManifest(
                OfflineAudioManifest(
                    bookId = book.id,
                    title = book.title,
                    author = book.author,
                    coverUrl = localCoverUri ?: book.coverUrl,
                    source = book.source.name,
                    downloadedAtEpochMs = System.currentTimeMillis(),
                    tracks = manifestTracks,
                    connectionId = book.connectionId,
                    downloadKey = key,
                )
            )
            _downloadedKeys.update { it + key }
        }
        bookCacheDao.updateDownloadedStatus(
            bookId = book.id,
            connectionId = book.connectionId,
            downloaded = true,
            nowMs = System.currentTimeMillis(),
        )
        updateProgress {
            it + (
                key to OfflineDownloadProgress(
                    downloadKey = key,
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
        if (!storage.isDownloaded(key)) {
            _downloadedKeys.update { it - key }
            bookCacheDao.updateDownloadedStatus(book.id, book.connectionId, downloaded = false, nowMs = System.currentTimeMillis())
            if (cancelSignal.get()) throw CancellationException("Cancelled")
            throw TrackDownloadIntegrityException("Downloaded audio failed validation")
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
                val file = storage.coverFile(book.offlineDownloadKey)
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

    private fun scopedWorkName(key: String): String =
        if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) workName(key)
        else "profile:${locations.profileId}:${workName(key)}"

    companion object {
        private const val WORK_TAG = "audiobook-download"
        fun workName(key: String): String = "audiobook-download:$key"
    }
}
