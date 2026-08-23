package com.enve.app.data.offline

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.app.data.repository.AggregatorRepository
import dagger.hilt.android.qualifiers.ApplicationContext
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
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ComicOfflineService @Inject constructor(
    @ApplicationContext private val context: android.content.Context,
    private val aggregatorRepository: AggregatorRepository,
    private val storage: ComicOfflineStorage,
    private val okHttpClient: OkHttpClient,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val cancelSignals = ConcurrentHashMap<String, AtomicBoolean>()

    private val _progressByBookId = MutableStateFlow<Map<String, ComicDownloadProgress>>(emptyMap())
    val progressByBookId: StateFlow<Map<String, ComicDownloadProgress>> = _progressByBookId.asStateFlow()

    private val _downloadedBookIds = MutableStateFlow(storage.listDownloadedBookIds())
    val downloadedBookIds: StateFlow<Set<String>> = _downloadedBookIds.asStateFlow()

    fun isDownloaded(bookId: String): Boolean = storage.isDownloaded(bookId)

    fun getLocalFile(bookId: String): File? = storage.getDownloadedFile(bookId)

    fun listDownloadedManifests(): List<Book> = storage.listManifests()

    fun startDownload(book: Book) {
        if (isDownloaded(book.id)) {
            _downloadedBookIds.update { it + book.id }
            return
        }
        val existing = _progressByBookId.value[book.id]
        if (existing?.status == ComicDownloadStatus.DOWNLOADING || existing?.status == ComicDownloadStatus.QUEUED) {
            return
        }

        val cancelSignal = AtomicBoolean(false)
        cancelSignals[book.id] = cancelSignal

        _progressByBookId.update {
            it + (book.id to ComicDownloadProgress(book.id, book.title, ComicDownloadStatus.QUEUED, 0f))
        }

        scope.launch {
            try {
                downloadOne(book, cancelSignal)
            } catch (e: kotlinx.coroutines.CancellationException) {
                _progressByBookId.update {
                    it + (book.id to ComicDownloadProgress(book.id, book.title, ComicDownloadStatus.CANCELLED, 0f))
                }
                throw e
            } catch (e: Exception) {
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

    fun startDownloadAll(books: List<Book>) {
        for (book in books) startDownload(book)
    }

    fun cancelDownload(bookId: String) {
        cancelSignals[bookId]?.set(true)
    }

    fun removeDownload(bookId: String) {
        cancelDownload(bookId)
        storage.removeDownload(bookId)
        _downloadedBookIds.update { it - bookId }
        _progressByBookId.update { it - bookId }
    }

    private suspend fun downloadOne(book: Book, cancelSignal: AtomicBoolean) {
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
            input.use { inp -> FileOutputStream(target).use { out -> inp.copyTo(out) } }
            if (target.length() < 1024) {
                target.delete()
                error("Local file too small for ${book.title}")
            }
            storage.commit(target)
            storage.saveManifest(book)
            _downloadedBookIds.update { it + book.id }
            _progressByBookId.update {
                it + (book.id to ComicDownloadProgress(book.id, book.title, ComicDownloadStatus.COMPLETED, 1f))
            }
            return
        }

        var tmp = storage.existingTempFile(book.id)
        var resumeOffset = tmp?.length()?.takeIf { it > 0L } ?: 0L
        fun requestFor(offset: Long): Request =
            Request.Builder().url(url).get().apply {
                if (offset > 0L) header("Range", "bytes=$offset-")
            }.build()

        var response = okHttpClient.newCall(requestFor(resumeOffset)).execute()
        if (resumeOffset > 0L && response.code == 416) {
            response.close()
            tmp?.delete()
            tmp = null
            resumeOffset = 0L
            response = okHttpClient.newCall(requestFor(0L)).execute()
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

            if (target.length() < 1024) {
                target.delete()
                error("Downloaded file too small for ${book.title}")
            }

            storage.commit(target)
            storage.saveManifest(book)
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
}

data class ComicDownloadProgress(
    val bookId: String,
    val title: String,
    val status: ComicDownloadStatus,
    val progress: Float,
    val errorMessage: String? = null,
)

enum class ComicDownloadStatus { QUEUED, DOWNLOADING, COMPLETED, CANCELLED, FAILED }
