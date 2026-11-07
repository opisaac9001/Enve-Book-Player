package com.enve.app.data.fileimport

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.IOException
import java.net.URLDecoder
import java.util.UUID
import java.util.concurrent.TimeUnit

class DropboxLinkDownloader internal constructor(
    client: OkHttpClient,
    private val workDirectory: File,
) {
    constructor(workDirectory: File) : this(OkHttpClient(), workDirectory)

    private val client = client.newBuilder()
        .followRedirects(false)
        .followSslRedirects(false)
        .cookieJar(CookieJar.NO_COOKIES)
        .cache(null)
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    suspend fun download(link: DropboxSharedLink, onBytesCopied: (Long) -> Unit = {}): File = withContext(Dispatchers.IO) {
        check(workDirectory.isDirectory || workDirectory.mkdirs())
        removeStaleFiles()
        val target = File(workDirectory, "${UUID.randomUUID()}$PART_SUFFIX")
        try {
            var url = link.downloadUrl
            repeat(MAX_REDIRECTS + 1) {
                val next = fetch(url) { response ->
                    when {
                        response.isRedirect -> nextLocation(url, response)
                        response.code == 200 -> {
                            save(response, link, target, onBytesCopied)
                            null
                        }
                        response.code == 401 || response.code == 403 || response.code == 404 || response.code == 410 ->
                            throw IOException(UNAVAILABLE)
                        else -> throw IOException("Dropbox couldn't send the file (HTTP ${response.code}).")
                    }
                }
                if (next == null) return@withContext target
                url = next
            }
            throw IOException(TOO_MANY_REDIRECTS)
        } catch (failure: Throwable) {
            target.delete()
            if (failure is IOException) currentCoroutineContext().ensureActive()
            throw failure
        }
    }

    private suspend fun <T> fetch(url: HttpUrl, read: suspend (Response) -> T): T {
        val call = client.newCall(Request.Builder().url(url).header("Accept", "*/*").build())
        return coroutineScope {
            val watcher = launch(start = CoroutineStart.UNDISPATCHED) {
                try {
                    awaitCancellation()
                } finally {
                    call.cancel()
                }
            }
            try {
                execute(call).use { read(it) }
            } finally {
                watcher.cancel()
            }
        }
    }

    private fun execute(call: Call): Response = try {
        call.execute()
    } catch (_: IOException) {
        throw IOException(UNREACHABLE)
    }

    private fun nextLocation(current: HttpUrl, response: Response): HttpUrl {
        val next = response.header("Location")?.let(current::resolve) ?: throw IOException(UNTRUSTED_REDIRECT)
        if (!isTrustedRedirect(next)) throw IOException(UNTRUSTED_REDIRECT)
        return next
    }

    private suspend fun save(response: Response, link: DropboxSharedLink, target: File, onBytesCopied: (Long) -> Unit) {
        val body = response.body ?: throw IOException(NOT_A_FILE)
        val type = body.contentType()
        if (type != null && (type.type == "text" || type.subtype == "html" || type.subtype == "xhtml+xml")) throw IOException(NOT_A_FILE)
        val declared = body.contentLength()
        if (declared > MAX_BYTES) throw IOException(TOO_LARGE)
        servedFileName(response.header("Content-Disposition"))?.let { served ->
            if (ImportableFormats.extension(served) != ImportableFormats.extension(link.fileName)) throw IOException(DIFFERENT_FILE)
        }
        var total = 0L
        try {
            body.byteStream().use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (total == 0L) rejectUnexpectedContent(buffer, count, link)
                        total += count
                        if (total > MAX_BYTES) throw IOException(TOO_LARGE)
                        output.write(buffer, 0, count)
                        onBytesCopied(count.toLong())
                    }
                    output.fd.sync()
                }
            }
        } catch (failure: IOException) {
            currentCoroutineContext().ensureActive()
            if (failure.message in safeMessages) throw failure
            throw IOException(INTERRUPTED)
        }
        if (total == 0L) throw IOException(NOT_A_FILE)
        if (declared >= 0L && total != declared) throw IOException(INTERRUPTED)
    }

    private fun rejectUnexpectedContent(buffer: ByteArray, count: Int, link: DropboxSharedLink) {
        val head = String(buffer, 0, minOf(count, 512), Charsets.ISO_8859_1).trimStart('﻿', 'ï', '»', '¿', ' ', '\t', '\r', '\n').lowercase()
        if (head.startsWith("<!doctype html") || head.startsWith("<html") || head.startsWith("<head") || head.startsWith("<body")) {
            throw IOException(NOT_A_FILE)
        }
        val zip = count >= 4 && buffer[0] == 'P'.code.toByte() && buffer[1] == 'K'.code.toByte() &&
            buffer[2] == 3.toByte() && buffer[3] == 4.toByte()
        if (zip && ImportableFormats.extension(link.fileName) !in ImportableFormats.zipContainerExtensions) {
            throw IOException(DIFFERENT_FILE)
        }
    }

    private fun removeStaleFiles() {
        val cutoff = System.currentTimeMillis() - STALE_AFTER_MS
        workDirectory.listFiles().orEmpty()
            .filter { it.isFile && it.name.endsWith(PART_SUFFIX) && it.lastModified() < cutoff }
            .forEach { it.delete() }
    }

    companion object {
        const val UNAVAILABLE = "This Dropbox link isn't available. Check that it's shared with anyone who has the link."
        const val UNREACHABLE = "Couldn't reach Dropbox. Check your connection and try again."
        const val UNTRUSTED_REDIRECT = "Dropbox sent the download somewhere Enve doesn't trust, so it was stopped."
        const val TOO_MANY_REDIRECTS = "Dropbox redirected the download too many times."
        const val NOT_A_FILE = "Dropbox returned a web page instead of the file. The link may need you to sign in, or it may have expired."
        const val DIFFERENT_FILE = "Dropbox sent a different kind of file than the link names, such as a folder archive."
        const val TOO_LARGE = "That Dropbox file is too large to import."
        const val INTERRUPTED = "The Dropbox download was interrupted. Try again."

        private val safeMessages = setOf(NOT_A_FILE, DIFFERENT_FILE, TOO_LARGE)
        private const val MAX_REDIRECTS = 5
        private const val MAX_BYTES = 8L * 1_024L * 1_024L * 1_024L
        private const val BUFFER_BYTES = 256 * 1_024
        private const val PART_SUFFIX = ".part"
        private const val STALE_AFTER_MS = 6L * 60L * 60L * 1_000L

        internal fun isTrustedRedirect(url: HttpUrl): Boolean {
            if (!url.isHttps || url.username.isNotEmpty() || url.password.isNotEmpty() || url.port != 443 || url.fragment != null) return false
            val host = url.host
            return host == "dropbox.com" || host.endsWith(".dropbox.com") ||
                host == "dropboxusercontent.com" || host.endsWith(".dropboxusercontent.com")
        }

        internal fun servedFileName(disposition: String?): String? {
            if (disposition.isNullOrBlank()) return null
            val extended = Regex("""filename\*\s*=\s*([^']*)'[^']*'([^;]+)""", RegexOption.IGNORE_CASE).find(disposition)
            val decoded = extended?.let { match ->
                try {
                    URLDecoder.decode(match.groupValues[2].trim().replace("+", "%2B"), match.groupValues[1].ifBlank { "UTF-8" })
                } catch (_: IllegalArgumentException) {
                    null
                } catch (_: java.io.UnsupportedEncodingException) {
                    null
                }
            }
            val plain = Regex("""filename\s*=\s*"([^"]*)"|filename\s*=\s*([^;]+)""", RegexOption.IGNORE_CASE).find(disposition)
                ?.let { match -> match.groupValues[1].ifEmpty { match.groupValues[2] }.trim() }
            return (decoded ?: plain)?.takeIf { it.isNotBlank() }
        }
    }
}
