package com.enve.app.data.offline

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.local.BookCacheDao
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
    private val cancelSignals = ConcurrentHashMap<String, AtomicBoolean>()

    private val _progressByBookId = MutableStateFlow<Map<String, ComicDownloadProgress>>(emptyMap())
    val progressByBookId: StateFlow<Map<String, ComicDownloadProgress>> = _progressByBookId.asStateFlow()

    private val _downloadedBookIds = MutableStateFlow(storage.listDownloadedBookIds())
    val downloadedBookIds: StateFlow<Set<String>> = _downloadedBookIds.asStateFlow()

    fun isDownloaded(bookId: String): Boolean = storage.isDownloaded(bookId)

    fun getLocalFile(bookId: String): File? = storage.getDownloadedFile(bookId)

    fun listDownloadedManifests(): List<Book> = storage.listManifests()

    suspend fun detectReadAloud(book: Book): Book = kotlinx.coroutines.withContext(Dispatchers.IO) {
        val manifest = storage.getManifest(book.id)?.takeIf { it.uniqueKey == book.uniqueKey }
            ?: return@withContext book
        val file = storage.getDownloadedFile(book.id) ?: return@withContext book
        val detected = book.withDownloadedReadAloud(file, file.extension)
        if (detected.readAlongAvailable) {
            bookCache.markReadAlongAvailable(book.uniqueKey)
            storage.saveManifest(manifest.copy(readAlongAvailable = true, hasAudio = true, hasEbook = true))
        }
        detected
    }

    fun startDownload(book: Book) {
        synchronized(admissionLock) {
            check(acceptingDownloads) { "Downloads are paused for this profile." }
            if (isDownloaded(book.id)) {
                storage.clearPendingRequest(book.id)
                _downloadedBookIds.update { it + book.id }
                return
            }
            val existing = _progressByBookId.value[book.id]
            if (existing?.status == ComicDownloadStatus.DOWNLOADING || existing?.status == ComicDownloadStatus.QUEUED) {
                return
            }

            storage.savePendingRequest(book)
            val cancelSignal = AtomicBoolean(false)
            cancelSignals[book.id] = cancelSignal

            _progressByBookId.update {
                it + (book.id to ComicDownloadProgress(book.id, book.title, ComicDownloadStatus.QUEUED, 0f))
            }

            scope.launch {
                try {
                    downloadOne(book, cancelSignal)
                    storage.clearPendingRequest(book.id)
                } catch (e: kotlinx.coroutines.CancellationException) {
                    _progressByBookId.update {
                        it + (book.id to ComicDownloadProgress(book.id, book.title, ComicDownloadStatus.CANCELLED, 0f))
                    }
                    throw e
                } catch (e: Exception) {
                    currentCoroutineContext().ensureActive()
                    val cancelled = cancelSignal.get()
                    _progressByBookId.update { current ->
                        current + (book.id to ComicDownloadProgress(
                            bookId = book.id,
                            title = book.title,
                            status = if (cancelled) ComicDownloadStatus.CANCELLED else ComicDownloadStatus.FAILED,
                            progress = 0f,
                            errorMessage = if (cancelled) null else e.message,
                        ))
                    }
                } finally {
                    cancelSignals.remove(book.id)
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
                    if (acceptingDownloads) {
                        _progressByBookId.update { it - book.id }
                        startDownload(book)
                    }
                }
            }
        }
    }

    fun refreshCompletedDownloads() {
        _downloadedBookIds.value = storage.listDownloadedBookIds()
    }

    fun startDownloadAll(books: List<Book>) {
        for (book in books) startDownload(book)
    }

    fun cancelDownload(bookId: String) {
        storage.clearPendingRequest(bookId)
        cancelSignals[bookId]?.set(true)
    }

    fun removeDownload(bookId: String) {
        cancelDownload(bookId)
        storage.removeDownload(bookId)
        _downloadedBookIds.update { it - bookId }
        _progressByBookId.update { it - bookId }
    }

    private suspend fun downloadOne(book: Book, cancelSignal: AtomicBoolean) = okHttpClient.withDownloadCalls { calls ->
        val isStorytellerReadAloud = book.source == BookSource.STORYTELLER && book.readAlongAvailable
        val url = if (isStorytellerReadAloud) {
            aggregatorRepository.getReadaloudDownloadUrl(book.id, book.source, book.connectionId)
        } else {
            aggregatorRepository.getEbookDownloadUrl(book.id, book.source, book.connectionId)
        }
            ?: error("No download URL available for ${book.title}")
        val preferredExtension = if (isStorytellerReadAloud) "epub" else book.primaryFileType

        _progressByBookId.update {
            it + (book.id to ComicDownloadProgress(book.id, book.title, ComicDownloadStatus.DOWNLOADING, 0f))
        }

        if (url.startsWith("content://") || url.startsWith("file://")) {
            val ext = extensionFor(url, null, preferredExtension)
            val target = storage.createTempFile(book.id, ext)
            val input = context.contentResolver.openInputStream(android.net.Uri.parse(url))
                ?: error("Couldn't open the local file for ${book.title}")
            input.use { inp ->
                FileOutputStream(target).use { out ->
                    val buffer = ByteArray(32_768)
                    while (true) {
                        currentCoroutineContext().ensureActive()
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
            commitDownload(book, target, ext)
            _downloadedBookIds.update { it + book.id }
            _progressByBookId.update {
                it + (book.id to ComicDownloadProgress(book.id, book.title, ComicDownloadStatus.COMPLETED, 1f))
            }
            return@withDownloadCalls
        }

        var tmp = storage.existingTempFile(book.id)
        var resumeOffset = tmp?.length()?.takeIf { it > 0L } ?: 0L
        fun requestFor(offset: Long): Request =
            Request.Builder().url(url).get().apply {
                if (offset > 0L) header("Range", "bytes=$offset-")
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
            val total = when {
                resp.code == 206 && responseLength > 0L -> resumeOffset + responseLength
                responseLength > 0L -> responseLength
                else -> 0L
            }
            val ext = extensionFor(url, resp.header("Content-Type"), preferredExtension)
            val target = tmp ?: storage.createTempFile(book.id, ext).also { tmp = it }
            if (resumeOffset == 0L && target.exists()) target.delete()

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
                            _progressByBookId.update {
                                it + (book.id to ComicDownloadProgress(book.id, book.title, ComicDownloadStatus.DOWNLOADING, pct))
                            }
                        }
                    }
                }
            }

            if (target.length() == 0L) {
                target.delete()
                error("Downloaded file is empty for ${book.title}")
            }

            commitDownload(book, target, ext)
        }

        _downloadedBookIds.update { it + book.id }
        _progressByBookId.update {
            it + (book.id to ComicDownloadProgress(book.id, book.title, ComicDownloadStatus.COMPLETED, 1f))
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

    private suspend fun commitDownload(book: Book, target: File, extension: String) {
        validateEpub(target, extension)
        val detected = book.withDownloadedReadAloud(target, extension)
        currentCoroutineContext().ensureActive()
        storage.commit(target)
        storage.saveManifest(detected)
        if (detected.readAlongAvailable) bookCache.markReadAlongAvailable(book.uniqueKey)
    }

    private fun validateEpub(file: File, extension: String) {
        if (!extension.equals("epub", ignoreCase = true)) return
        try {
            ZipFile(file).use { require(it.entries().hasMoreElements()) }
        } catch (e: Exception) {
            file.delete()
            throw IllegalStateException("The server did not return a valid EPUB file", e)
        }
    }
}

internal fun Book.withDownloadedReadAloud(file: File, extension: String): Book {
    if (readAlongAvailable || !extension.equals("epub", true)) return this
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
    val bookId: String,
    val title: String,
    val status: ComicDownloadStatus,
    val progress: Float,
    val errorMessage: String? = null,
)

enum class ComicDownloadStatus { QUEUED, DOWNLOADING, COMPLETED, CANCELLED, FAILED }
