package com.enve.app.webimport

import com.enve.app.webimport.WebStoryImportException.Reason
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext

internal data class WebStoryLimits(
    val maxPageBytes: Long = 6L * 1024 * 1024,
    val maxDownloadBytes: Long = 200L * 1024 * 1024,
    val maxTotalBytes: Long = 320L * 1024 * 1024,
    val maxResponses: Int = 2_200,
    val maxRedirects: Int = 5,
    val maxIndexPages: Int = 50,
    val maxChapters: Int = 2_000,
    val maxEpubBytes: Long = 256L * 1024 * 1024,
)

internal class WebFetchBudget(private val limits: WebStoryLimits) {
    private var responses = 0
    private var bytes = 0L

    fun countResponse() {
        if (++responses > limits.maxResponses) throw WebStoryImportException(Reason.STORY_TOO_LARGE)
    }

    fun countBytes(count: Int) {
        bytes += count
        if (bytes > limits.maxTotalBytes) throw WebStoryImportException(Reason.STORY_TOO_LARGE)
    }
}

internal sealed interface WebFetched {
    val url: HttpUrl

    class Html(override val url: HttpUrl, val document: Document) : WebFetched
    class Text(override val url: HttpUrl, val text: String) : WebFetched
    class Ebook(override val url: HttpUrl, val file: File, val format: WebStoryFileFormat) : WebFetched
}

internal class WebPageFetcher(
    private val client: OkHttpClient,
    private val limits: WebStoryLimits,
) {

    suspend fun fetchDocument(url: HttpUrl, budget: WebFetchBudget, origin: HttpUrl?): WebFetched.Html =
        fetch(url, budget, origin, downloadDir = null) as? WebFetched.Html
            ?: throw WebStoryImportException(Reason.UNSUPPORTED)

    suspend fun fetchEntry(url: HttpUrl, budget: WebFetchBudget, downloadDir: File): WebFetched =
        fetch(url, budget, origin = null, downloadDir = downloadDir)

    private suspend fun fetch(start: HttpUrl, budget: WebFetchBudget, origin: HttpUrl?, downloadDir: File?): WebFetched {
        var url = start
        repeat(limits.maxRedirects + 1) {
            if (origin != null && !WebStoryUrls.sameOrigin(origin, url)) throw WebStoryImportException(Reason.OFF_ORIGIN)
            budget.countResponse()
            val outcome: Any = execute(url) { response ->
                if (response.isRedirect) {
                    response.header("Location")?.let { response.request.url.resolve(it) }
                        ?.let(WebStoryUrls::withoutFragment)
                        ?: throw WebStoryImportException(Reason.UNSUPPORTED)
                } else {
                    ensureSuccess(response)
                    read(response, budget, downloadDir)
                }
            }
            when (outcome) {
                is WebFetched -> return outcome
                is HttpUrl -> url = outcome
            }
        }
        throw WebStoryImportException(Reason.SERVER_ERROR)
    }

    private suspend fun read(response: Response, budget: WebFetchBudget, downloadDir: File?): WebFetched {
        val body = response.body ?: throw WebStoryImportException(Reason.NO_CONTENT)
        val url = response.request.url
        val type = body.contentType()
        val format = WebStoryFileFormat.detect(type?.mediaTypeName(), url)
        return when {
            format != null && downloadDir != null -> WebFetched.Ebook(url, download(body, url, budget, downloadDir, format), format)
            type == null || type.isHtml() -> {
                val bytes = readBounded(body, budget)
                WebFetched.Html(url, Jsoup.parse(ByteArrayInputStream(bytes), type?.charset()?.name(), url.toString()))
            }
            type.type == "text" && type.subtype == "plain" && downloadDir != null ->
                WebFetched.Text(url, readBounded(body, budget).toString(type.charset() ?: Charsets.UTF_8))
            else -> throw WebStoryImportException(Reason.UNSUPPORTED)
        }
    }

    private suspend fun readBounded(body: ResponseBody, budget: WebFetchBudget): ByteArray {
        val output = ByteArrayOutputStream()
        copyBounded(body, output, limits.maxPageBytes, budget)
        return output.toByteArray()
    }

    private suspend fun download(
        body: ResponseBody,
        url: HttpUrl,
        budget: WebFetchBudget,
        directory: File,
        format: WebStoryFileFormat,
    ): File {
        directory.mkdirs()
        val baseName = url.pathSegments.lastOrNull().orEmpty()
            .substringBeforeLast('.')
            .replace(unsafeFileNameChars, "_")
            .trim('_', '.', ' ')
            .take(MAX_FILE_NAME_LENGTH)
            .ifEmpty { "book" }
        val file = File(directory, "$baseName.${format.extension}")
        try {
            FileOutputStream(file).use { copyBounded(body, it, limits.maxDownloadBytes, budget) }
            val header = ByteArray(format.headerLength)
            val read = file.inputStream().use { it.read(header) }
            if (read < header.size || !format.matches(header)) throw WebStoryImportException(Reason.UNSUPPORTED)
            return file
        } catch (e: Throwable) {
            file.delete()
            throw e
        }
    }

    private suspend fun copyBounded(body: ResponseBody, output: OutputStream, limit: Long, budget: WebFetchBudget) {
        if (body.contentLength() > limit) throw WebStoryImportException(Reason.TOO_LARGE)
        val input = body.byteStream()
        val buffer = ByteArray(READ_CHUNK_BYTES)
        var total = 0L
        while (true) {
            coroutineContext.ensureActive()
            val count = input.read(buffer)
            if (count == -1) break
            total += count
            if (total > limit) throw WebStoryImportException(Reason.TOO_LARGE)
            budget.countBytes(count)
            output.write(buffer, 0, count)
        }
    }

    private suspend fun <T> execute(url: HttpUrl, handle: suspend (Response) -> T): T = withContext(Dispatchers.IO) {
        val call = client.newCall(
            Request.Builder()
                .url(url)
                .header("User-Agent", USER_AGENT)
                .header("Accept", ACCEPT)
                .build(),
        )
        val canceller = launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                awaitCancellation()
            } finally {
                call.cancel()
            }
        }
        try {
            call.execute().use { handle(it) }
        } catch (e: IOException) {
            ensureActive()
            throw WebStoryImportException(Reason.NETWORK, cause = e)
        } finally {
            canceller.cancel()
        }
    }

    private fun ensureSuccess(response: Response) {
        if (response.isSuccessful) return
        val challenged = response.header("cf-mitigated").equals("challenge", ignoreCase = true) ||
            response.code in setOf(403, 503) && response.header("Server").orEmpty().contains("cloudflare", ignoreCase = true)
        val reason = when {
            challenged -> Reason.BROWSER_CHECK
            response.code == 401 || response.code == 403 -> Reason.ACCESS_DENIED
            response.code == 404 || response.code == 410 -> Reason.NOT_FOUND
            response.code == 429 -> Reason.RATE_LIMITED
            else -> Reason.SERVER_ERROR
        }
        throw WebStoryImportException(reason)
    }

    private fun MediaType.mediaTypeName() = "$type/$subtype".lowercase()

    private fun MediaType.isHtml() =
        type == "text" && subtype == "html" || type == "application" && subtype == "xhtml+xml"

    companion object {
        private const val READ_CHUNK_BYTES = 64 * 1024
        private const val MAX_FILE_NAME_LENGTH = 80
        private val unsafeFileNameChars = Regex("[^A-Za-z0-9 ._-]")
        private const val USER_AGENT = "EnveBookPlayer (Android; web story import)"
        private const val ACCEPT = "text/html,application/xhtml+xml,text/plain;q=0.9,application/epub+zip;q=0.8,*/*;q=0.1"

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .callTimeout(120, TimeUnit.SECONDS)
            .build()
    }
}
