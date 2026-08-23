package com.enve.app.data.librarian

import android.content.Context
import com.enve.app.data.repository.AggregatorRepository
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.app.readium.ReadiumManager
import com.enve.app.document.NativeKindleEpubConverter
import com.enve.app.document.OnDeviceEbookNormalizer
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.jsoup.Jsoup
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.services.positionsByReadingOrder
import org.readium.r2.shared.util.getOrElse
import java.io.File
import java.io.FileOutputStream
import javax.inject.Inject
import javax.inject.Singleton

class EbookContextException(message: String) : Exception(message)

@Singleton
class EbookContextService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val okHttpClient: OkHttpClient,
    private val aggregatorRepository: AggregatorRepository,
    private val grimmoryRepository: GrimmoryRepository,
    private val store: EbookContextStore,
    private val readiumManager: ReadiumManager,
) {
    private val _buildingBookIds = MutableStateFlow<Set<String>>(emptySet())
    val buildingBookIds: StateFlow<Set<String>> = _buildingBookIds.asStateFlow()

    private val _progressByBook = MutableStateFlow<Map<String, Double>>(emptyMap())
    val progressByBook: StateFlow<Map<String, Double>> = _progressByBook.asStateFlow()

    private val _statusByBook = MutableStateFlow<Map<String, String>>(emptyMap())
    val statusByBook: StateFlow<Map<String, String>> = _statusByBook.asStateFlow()

    suspend fun contextFor(book: LibrarianBookRef): EbookContext {
        store.load(book.stableId)?.takeIf { it.chunks.isNotEmpty() }?.let { return it }
        return prepareContext(book)
    }

    suspend fun prepareContext(book: LibrarianBookRef): EbookContext {
        store.load(book.stableId)?.takeIf { it.chunks.isNotEmpty() }?.let { return it }
        if (_buildingBookIds.value.contains(book.stableId)) {
            return store.load(book.stableId) ?: EbookContext(
                manifest = EbookContextManifest(
                    bookStableId = book.stableId,
                    status = BookContextStatus.GENERATING,
                    createdAtEpochMs = System.currentTimeMillis(),
                    updatedAtEpochMs = System.currentTimeMillis(),
                    chunkCount = 0,
                ),
                chunks = emptyList(),
            )
        }

        _buildingBookIds.update { it + book.stableId }
        _progressByBook.update { it + (book.stableId to 0.0) }
        _statusByBook.update { it + (book.stableId to "Preparing ebook text") }

        return try {
            store.markGenerating(book.stableId)
            val file = resolveEpub(book)
            val chunks = buildContext(book, file)
            if (chunks.isEmpty()) throw EbookContextException("Enve could not find readable text in this ebook.")
            store.save(book.stableId, chunks)
            _progressByBook.update { it + (book.stableId to 1.0) }
            _statusByBook.update { it - book.stableId }
            store.load(book.stableId) ?: EbookContext(
                manifest = EbookContextManifest(
                    bookStableId = book.stableId,
                    status = BookContextStatus.READY,
                    createdAtEpochMs = System.currentTimeMillis(),
                    updatedAtEpochMs = System.currentTimeMillis(),
                    chunkCount = chunks.size,
                ),
                chunks = chunks,
            )
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (error: Exception) {

            val friendly = (error as? EbookContextException)?.message
                ?: "The book's text couldn't be prepared."
            android.util.Log.w("EbookContextService", "prepareContext failed for ${book.title}", error)
            runCatching { store.markFailed(book.stableId, friendly) }
            _statusByBook.update { it + (book.stableId to friendly) }
            throw if (error is EbookContextException) error else EbookContextException(friendly)
        } finally {
            _buildingBookIds.update { it - book.stableId }
        }
    }

    private suspend fun resolveEpub(book: LibrarianBookRef): File {
        _statusByBook.update { it + (book.stableId to "Downloading ebook") }
        val sourceFile = downloadSource(book)
        _statusByBook.update { it + (book.stableId to "Opening ebook") }
        return OnDeviceEbookNormalizer(
            kindleConverter = NativeKindleEpubConverter(context),
        ).normalizeToEpub(
            source = sourceFile,
            format = book.sourceFormat,
            outputDir = File(context.cacheDir, "librarian-normalized-ebooks"),
            outputName = fileSafeName(book.stableId),
        )
    }

    private suspend fun downloadSource(book: LibrarianBookRef): File = withContext(Dispatchers.IO) {
        val downloadUrl = aggregatorRepository.getEbookDownloadUrl(book.bookId, book.source, book.connectionId)
            ?: grimmoryRepository.getEbookDownloadUrl(book.bookId)
        val dir = File(context.cacheDir, "librarian-ebook-sources").also { it.mkdirs() }
        val safeName = fileSafeName(book.stableId)
        val cached = File(dir, "$safeName.${book.sourceFormat.extension}")
        if (cached.exists() && cached.length() > 10_240L) return@withContext cached

        if (downloadUrl.startsWith("content://") || downloadUrl.startsWith("file://")) {
            val temp = File(dir, "$safeName.tmp")
            val input = context.contentResolver.openInputStream(android.net.Uri.parse(downloadUrl))
                ?: throw EbookContextException("Couldn't open the local book file.")
            input.use { inp -> FileOutputStream(temp).use { out -> inp.copyTo(out) } }
            if (temp.length() < 1024L) {
                temp.delete()
                throw EbookContextException("The local book file was empty.")
            }
            if (cached.exists()) cached.delete()
            if (!temp.renameTo(cached)) {
                temp.copyTo(cached, overwrite = true)
                temp.delete()
            }
            return@withContext cached
        }

        val request = Request.Builder().url(downloadUrl).build()
        val temp = File(dir, "$safeName.tmp")
        okHttpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw EbookContextException("Download failed: HTTP ${response.code}")
            val body = response.body ?: throw EbookContextException("Download failed: empty response")
            val length = body.contentLength()

            FileOutputStream(temp).use { output ->
                body.byteStream().use { input ->
                    val buffer = ByteArray(16_384)
                    var total = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read == -1) break
                        output.write(buffer, 0, read)
                        total += read
                        if (length > 0L) {
                            _progressByBook.update { it + (book.stableId to (total.toDouble() / length.toDouble()).coerceIn(0.0, 0.35)) }
                        }
                    }
                }
            }
        }
        if (temp.length() < 1024L) {
            temp.delete()
            throw EbookContextException("Downloaded ebook was empty.")
        }
        if (cached.exists()) cached.delete()
        if (!temp.renameTo(cached)) {
            temp.copyTo(cached, overwrite = true)
            temp.delete()
        }
        cached
    }

    private suspend fun buildContext(book: LibrarianBookRef, epubFile: File): List<EbookContextChunk> {
        val readium = readiumManager
        val asset = readium.assetRetriever.retrieve(epubFile).getOrElse {
            throw EbookContextException("Cannot read EPUB: ${it.message}")
        }
        val publication = readium.publicationOpener.open(asset, allowUserInteraction = false).getOrElse {
            throw EbookContextException("Cannot parse EPUB: ${it.message}")
        }
        return try {
            buildContext(book, publication)
        } finally {
            withContext(Dispatchers.IO) {
                runCatching { publication.close() }
            }
        }
    }

    private suspend fun buildContext(book: LibrarianBookRef, publication: Publication): List<EbookContextChunk> {
        _statusByBook.update { it + (book.stableId to "Reading EPUB text") }
        val readingOrder = publication.readingOrder
        if (readingOrder.isEmpty()) throw EbookContextException("This ebook has no readable sections.")
        val tocLinks = flattenLinks(publication.tableOfContents)
        val positionsByReadingOrder = withContext(Dispatchers.Default) {
            runCatching { publication.positionsByReadingOrder() }.getOrDefault(emptyList())
        }

        val drafts = mutableListOf<EbookContextChunk>()
        readingOrder.forEachIndexed { index, link ->
            _progressByBook.update {
                it + (book.stableId to (0.35 + (index.toDouble() / readingOrder.size.toDouble()) * 0.6).coerceIn(0.35, 0.95))
            }
            val text = readPlainText(publication, link)
            if (text.length <= 20) return@forEachIndexed

            val positions = positionsByReadingOrder.getOrNull(index).orEmpty()
            val fallbackStart = index.toDouble() / readingOrder.size.toDouble()
            val fallbackEnd = (index + 1).toDouble() / readingOrder.size.toDouble()
            val start = (positions.firstOrNull()?.locations?.totalProgression ?: fallbackStart).coerceIn(0.0, 1.0)
            val end = (positions.lastOrNull()?.locations?.totalProgression ?: fallbackEnd).coerceIn(0.0, 1.0)
            drafts += EbookContextChunk(
                id = "${book.stableId}-epub-$index",
                bookStableId = book.stableId,
                title = titleFor(link, tocLinks, index),
                href = link.url().toString(),
                index = index,
                startProgress = start,
                endProgress = maxOf(end, start + 0.0001).coerceAtMost(1.0),
                text = text,
            )
        }
        val sorted = drafts.sortedBy { it.startProgress }
        return sorted.mapIndexed { outputIndex, chunk ->
            val nextStart = sorted.getOrNull(outputIndex + 1)?.startProgress ?: 1.0
            chunk.copy(endProgress = maxOf(chunk.endProgress, minOf(1.0, nextStart), chunk.startProgress + 0.0001).coerceAtMost(1.0))
        }
    }

    private suspend fun readPlainText(publication: Publication, link: Link): String {
        val resource = publication.get(link) ?: return ""
        return try {
            val bytes = resource.read().getOrElse { return "" }
            val html = bytes.toString(Charsets.UTF_8)
            Jsoup.parse(html).text().replace(Regex("\\s+"), " ").trim()
        } finally {
            resource.close()
        }
    }

    private fun titleFor(link: Link, tocLinks: List<Link>, fallbackIndex: Int): String {
        val href = normalizedHref(link.url().toString())
        val tocTitle = tocLinks.firstOrNull { toc ->
            val tocHref = normalizedHref(toc.url().toString())
            tocHref == href || tocHref.endsWith(href) || href.endsWith(tocHref)
        }?.title?.trim()
        if (!tocTitle.isNullOrBlank()) return tocTitle
        link.title?.trim()?.takeIf { it.isNotBlank() }?.let { return it }
        return link.url().toString()
            .substringBefore("#")
            .substringAfterLast("/")
            .substringBeforeLast(".")
            .replace("-", " ")
            .ifBlank { "Section ${fallbackIndex + 1}" }
    }

    private fun flattenLinks(links: List<Link>): List<Link> =
        links.flatMap { listOf(it) + flattenLinks(it.children) }

    private fun normalizedHref(value: String): String =
        value.substringBefore("#")

    private fun fileSafeName(stableId: String): String {
        val cleaned = stableId.replace(Regex("[^a-zA-Z0-9_-]"), "_")
        if (cleaned.length <= 120) return cleaned
        return java.security.MessageDigest.getInstance("SHA-256")
            .digest(stableId.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }
}
