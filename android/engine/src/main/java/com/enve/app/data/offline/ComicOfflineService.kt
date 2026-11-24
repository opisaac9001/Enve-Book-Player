package com.enve.app.data.offline

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.util.runSuspendCatching
import com.enve.core.reader.MediaOverlayTimeline
import com.enve.app.data.repository.AggregatorRepository
import dagger.hilt.android.qualifiers.ApplicationContext
import com.enve.core.di.ApplicationScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import com.enve.core.data.remote.ConnectionScope
import kotlin.coroutines.EmptyCoroutineContext
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipFile
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ComicOfflineService @Inject constructor(
    @ApplicationContext private val context: android.content.Context,
    private val aggregatorRepository: AggregatorRepository,
    private val storage: ComicOfflineStorage,
    private val okHttpClient: OkHttpClient,
    private val bookCache: BookCacheDao,
    @ApplicationScope parentScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private val scope = CoroutineScope(SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.IO)
    private val admissionLock = Any()
    private var acceptingDownloads = true
    private val transfers = DownloadTransferLocks()
    private val jobs = mutableMapOf<String, Job>()
    private val cancelSignals = ConcurrentHashMap<String, AtomicBoolean>()

    private val _progressByDownloadKey = MutableStateFlow<Map<String, ComicDownloadProgress>>(emptyMap())
    val progressByDownloadKey: StateFlow<Map<String, ComicDownloadProgress>> = _progressByDownloadKey.asStateFlow()

    private val _downloadedKeys = MutableStateFlow(storage.listDownloadedKeys())
    val downloadedKeys: StateFlow<Set<String>> = _downloadedKeys.asStateFlow()

    init {
        scope.launch { registerRecoveredDownloads() }
    }

    fun isDownloaded(key: String): Boolean = storage.isDownloaded(key)

    fun getLocalFile(key: String): File? = storage.getDownloadedFile(key)

    fun listDownloadedManifests(): List<Book> = storage.listManifests()

    suspend fun detectReadAloud(book: Book): Book = kotlinx.coroutines.withContext(Dispatchers.IO) {
        val key = book.offlineDownloadKey
        val manifest = storage.getManifest(key)?.takeIf { it.offlineDownloadKey == key }
            ?: return@withContext book
        val file = storage.getDownloadedFile(key) ?: return@withContext book
        val detected = book.withDownloadedReadAloud(file, file.extension)
        if (detected.readAlongAvailable) {
            bookCache.markReadAlongAvailable(book.uniqueKey)
            synchronized(admissionLock) {
                if (!isRecoveredLocalBookId(manifest.id) && storage.isDownloaded(key) && storage.getManifest(key) == manifest) {
                    storage.saveManifest(manifest.copy(readAlongAvailable = true, hasAudio = true, hasEbook = true))
                }
            }
        }
        detected
    }

    private suspend fun registerRecoveredDownloads() {
        storage.listManifests().filter { isRecoveredLocalBookId(it.id) }.forEach { book ->
            runSuspendCatching { bookCache.insertIfAbsent(book.toCachedBook()) }
                .onFailure { android.util.Log.w("ComicOfflineService", "Recovered download ${book.offlineDownloadKey} was not registered", it) }
        }
    }

    private fun publish(book: Book, status: ComicDownloadStatus, progress: Float, errorMessage: String? = null) {
        val key = book.offlineDownloadKey
        _progressByDownloadKey.update {
            it + (key to ComicDownloadProgress(key, book.id, book.title, status, progress, errorMessage))
        }
    }

    fun startDownload(book: Book) {
        val key = book.offlineDownloadKey
        synchronized(admissionLock) {
            check(acceptingDownloads) { "Downloads are paused for this profile." }
            if (isDownloaded(key)) {
                storage.clearPendingRequest(key)
                _downloadedKeys.update { it + key }
                return
            }
            val existing = _progressByDownloadKey.value[key]
            if (existing?.status == ComicDownloadStatus.DOWNLOADING || existing?.status == ComicDownloadStatus.QUEUED) {
                return
            }

            storage.savePendingRequest(book)
            val cancelSignal = AtomicBoolean(false)
            cancelSignals[key] = cancelSignal

            publish(book, ComicDownloadStatus.QUEUED, 0f)

            val context = book.connectionId?.let { ConnectionScope.asContextElement(it) } ?: EmptyCoroutineContext
            val job = scope.launch(context) {
                try {
                    transfers.withKey(key) { downloadOne(book, cancelSignal) }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    synchronized(admissionLock) {
                        if (cancelSignals[key] === cancelSignal) publish(book, ComicDownloadStatus.CANCELLED, 0f)
                    }
                    throw e
                } catch (e: Exception) {
                    currentCoroutineContext().ensureActive()
                    synchronized(admissionLock) {
                        if (cancelSignals[key] === cancelSignal) publish(book, ComicDownloadStatus.FAILED, 0f, e.message)
                    }
                }
            }
            jobs[key] = job
            job.invokeOnCompletion {
                synchronized(admissionLock) {
                    if (cancelSignals.remove(key, cancelSignal)) jobs.remove(key)
                }
            }
        }
    }

    suspend fun pauseAllAndAwait() {
        val jobs = synchronized(admissionLock) {
            acceptingDownloads = false
            scope.coroutineContext[Job]?.children?.toList().orEmpty()
        }
        jobs.forEach { it.cancelAndJoin() }
    }

    fun resumeDownloads() {
        synchronized(admissionLock) { acceptingDownloads = true }
        scope.launch {
            storage.listPendingRequests().forEach { book ->
                synchronized(admissionLock) {
                    if (acceptingDownloads && jobs[book.offlineDownloadKey] == null && storage.hasPendingRequest(book.offlineDownloadKey)) {
                        _progressByDownloadKey.update { it - book.offlineDownloadKey }
                        startDownload(book)
                    }
                }
            }
        }
    }

    fun refreshCompletedDownloads() {
        _downloadedKeys.value = storage.listDownloadedKeys()
    }

    fun startDownloadAll(books: List<Book>) {
        for (book in books) startDownload(book)
    }

    fun cancelDownload(key: String) = synchronized(admissionLock) {
        cancelSignals.remove(key)?.set(true)
        jobs.remove(key)?.cancel()
        storage.clearPendingRequest(key)
        _progressByDownloadKey.update { current ->
            val active = current[key]
            if (active != null && (active.status == ComicDownloadStatus.DOWNLOADING || active.status == ComicDownloadStatus.QUEUED)) {
                current + (key to active.copy(status = ComicDownloadStatus.CANCELLED, progress = 0f))
            } else current
        }
    }

    fun removeDownload(key: String) = synchronized(admissionLock) {
        cancelDownload(key)
        storage.removeDownload(key)
        _downloadedKeys.update { it - key }
        _progressByDownloadKey.update { it - key }
    }

    private suspend fun downloadOne(book: Book, cancelSignal: AtomicBoolean) = okHttpClient.withDownloadCalls { calls ->
        val key = book.offlineDownloadKey
        val isStorytellerReadAloud = book.source == BookSource.STORYTELLER && book.readAlongAvailable
        val url = if (isStorytellerReadAloud) {
            aggregatorRepository.getReadaloudDownloadUrl(book.id, book.source, book.connectionId)
        } else {
            aggregatorRepository.getEbookDownloadUrl(book.id, book.source, book.connectionId)
        }
            ?: error("No download URL available for ${book.title}")
        val preferredExtension = if (isStorytellerReadAloud) "epub" else book.primaryFileType

        fun publishTransfer(progress: Float) = synchronized(admissionLock) {
            if (cancelSignal.get()) throw kotlinx.coroutines.CancellationException("Cancelled")
            publish(book, ComicDownloadStatus.DOWNLOADING, progress)
        }

        publishTransfer(0f)

        if (url.startsWith("content://") || url.startsWith("file://")) {
            val ext = extensionFor(url, null, preferredExtension)
            val target = storage.createTempFile(key, ext)
            val input = context.contentResolver.openInputStream(android.net.Uri.parse(url))
                ?: error("Couldn't open the local file for ${book.title}")
            input.use { inp ->
                FileOutputStream(target).use { out ->
                    val buffer = ByteArray(32_768)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        if (cancelSignal.get()) throw kotlinx.coroutines.CancellationException("Cancelled")
                        val count = inp.read(buffer)
                        if (count <= 0) break
                        out.write(buffer, 0, count)
                    }
                }
            }
            if (target.length() == 0L) {
                target.delete()
                error("Local file is empty for ${book.title}")
            }
            commitDownload(book, target, ext, cancelSignal)
            return@withDownloadCalls
        }

        var tmp = storage.existingTempFile(key)
        val validatorFile = storage.resumeValidatorFile(key)
        val storedValidator = validatorFile.takeIf { it.isFile }?.readText()?.takeIf { it.isNotBlank() }
        var resumeOffset = if (storedValidator == null) 0L else tmp?.length() ?: 0L
        if (resumeOffset == 0L) {
            tmp?.let { check(it.delete()) }
            tmp = null
        }
        fun requestFor(offset: Long): Request =
            Request.Builder().url(url).get().apply {
                if (offset > 0L) {
                    header("Range", "bytes=$offset-")
                    header("If-Range", checkNotNull(storedValidator))
                }
            }.build()

        var response = calls.execute(requestFor(resumeOffset))
        if (resumeOffset > 0L && response.code == 416) {
            response.close()
            tmp?.delete()
            tmp = null
            resumeOffset = 0L
            response = calls.execute(requestFor(0L))
        }

        response.use { resp ->
            if (resumeOffset > 0L && resp.code == 200) {
                tmp?.delete()
                tmp = null
                resumeOffset = 0L
            }
            if (!resp.isSuccessful) error("HTTP ${resp.code} downloading ${book.title}")
            val body = resp.body ?: error("Empty response body for ${book.title}")
            val responseLength = body.contentLength().takeIf { it > 0 } ?: 0L
            val responseValidator = strongResumeValidator(resp.header("ETag"), resp.header("Last-Modified"))
            val total = if (resp.code == 206) {
                val range = resp.header("Content-Range")
                try {
                    completeBookRangeLength(range, resumeOffset, body.contentLength(), storedValidator, responseValidator)
                } catch (e: IllegalStateException) {
                    tmp?.delete()
                    validatorFile.delete()
                    throw e
                }
            } else responseLength
            val ext = extensionFor(url, resp.header("Content-Type"), preferredExtension)
            val target = tmp ?: storage.createTempFile(key, ext).also { tmp = it }
            if (resumeOffset == 0L) {
                if (target.exists()) check(target.delete())
                if (responseValidator == null) validatorFile.delete() else validatorFile.writeText(responseValidator)
            }

            body.byteStream().use { input ->
                FileOutputStream(target, resumeOffset > 0L && resp.code == 206).use { output ->
                    val buffer = ByteArray(32_768)
                    var done = resumeOffset
                    var lastUpdate = 0L
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        if (cancelSignal.get()) throw kotlinx.coroutines.CancellationException("Cancelled")
                        val read = input.read(buffer)
                        if (read <= 0) break
                        output.write(buffer, 0, read)
                        done += read
                        val now = System.currentTimeMillis()
                        if (now - lastUpdate > 200L) {
                            lastUpdate = now
                            val pct = when {
                                total > 0 -> (done.toFloat() / total).coerceIn(0f, 1f)
                                else -> (done.toFloat() / (done + 2_000_000f)).coerceIn(0f, 0.95f)
                            }
                            publishTransfer(pct)
                        }
                    }
                }
            }

            if (target.length() == 0L) {
                target.delete()
                error("Downloaded file is empty for ${book.title}")
            }

            check(total == 0L || target.length() == total) { "Incomplete book download" }
            commitDownload(book, target, ext, cancelSignal)
        }
    }

    private fun extensionFor(url: String, contentType: String?, primaryFileType: String?): String {
        primaryFileType?.lowercase()?.takeIf { it.isNotBlank() }?.let { return it }
        if (!contentType.isNullOrBlank()) {
            when {
                contentType.contains("zip", ignoreCase = true) -> return "cbz"
                contentType.contains("rar", ignoreCase = true) -> return "cbr"
                contentType.contains("epub", ignoreCase = true) -> return "epub"
                contentType.contains("pdf", ignoreCase = true) -> return "pdf"
            }
        }
        val urlExt = url.substringAfterLast('.', "").lowercase().take(4)
        return urlExt.ifBlank { "bin" }
    }

    private suspend fun commitDownload(book: Book, target: File, extension: String, cancelSignal: AtomicBoolean) {
        validateEpub(target, extension)
        val detected = book.withDownloadedReadAloud(target, extension)
        currentCoroutineContext().ensureActive()
        val key = book.offlineDownloadKey
        synchronized(admissionLock) {
            if (cancelSignal.get()) throw kotlinx.coroutines.CancellationException("Cancelled")
            storage.saveManifest(detected)
            storage.commit(target)
            storage.resumeValidatorFile(key).delete()
            storage.clearPendingRequest(key)
            _downloadedKeys.update { it + key }
            publish(book, ComicDownloadStatus.COMPLETED, 1f)
        }
        if (detected.readAlongAvailable) {
            runSuspendCatching { bookCache.markReadAlongAvailable(book.uniqueKey) }
                .onFailure { android.util.Log.w("ComicOfflineService", "Could not update read-aloud availability", it) }
        }
    }

    private fun validateEpub(file: File, extension: String) {
        if (!extension.equals("epub", ignoreCase = true) && !extension.equals("kepub", ignoreCase = true)) return
        try {
            ZipFile(file).use { require(it.entries().hasMoreElements()) }
        } catch (e: Exception) {
            file.delete()
            throw IllegalStateException("The server did not return a valid EPUB file", e)
        }
    }
}

internal fun Book.withDownloadedReadAloud(file: File, extension: String): Book {
    if (readAlongAvailable || (!extension.equals("epub", true) && !extension.equals("kepub", true))) return this
    val narrated = try {
        MediaOverlayTimeline.load(file)?.clips?.isNotEmpty() == true
    } catch (error: kotlinx.coroutines.CancellationException) {
        throw error
    } catch (_: Exception) {
        false
    }
    return if (narrated) copy(readAlongAvailable = true, hasAudio = true, hasEbook = true) else this
}

data class ComicDownloadProgress(
    val downloadKey: String,
    val bookId: String,
    val title: String,
    val status: ComicDownloadStatus,
    val progress: Float,
    val errorMessage: String? = null,
)

enum class ComicDownloadStatus { QUEUED, DOWNLOADING, COMPLETED, CANCELLED, FAILED }
