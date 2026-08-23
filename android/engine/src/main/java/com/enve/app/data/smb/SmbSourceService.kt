package com.enve.app.data.smb

import android.content.Context
import android.net.Uri
import com.enve.app.playback.AudioPlaybackManager
import com.enve.core.data.importing.AudiobookFileGrouping
import com.enve.core.data.local.AudiobookGroupingOverrideStore
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import dagger.hilt.android.qualifiers.ApplicationContext
import fi.iki.elonen.NanoHTTPD
import jcifs.CIFSContext
import jcifs.context.BaseContext
import jcifs.config.PropertyConfiguration
import jcifs.smb.NtlmPasswordAuthenticator
import jcifs.smb.SmbFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.util.Properties
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.max
import kotlin.math.min

data class SmbCredentials(
    val username: String,
    val password: String,
    val domain: String = "",
)

@Singleton
class SmbSourceService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val groupingOverrides: AudiobookGroupingOverrideStore,
) {
    private val contentServer = SmbContentServer()
    private val audioExtensions = setOf("mp3", "m4b", "m4a", "mp4", "aac", "flac", "ogg", "opus", "wav")
    private val ebookExtensions = setOf("epub", "pdf", "cbz", "cbr", "cbx", "mobi", "azw3")

    suspend fun scan(rootUrl: String, credentials: SmbCredentials, sourceId: String): List<Book> = withContext(Dispatchers.IO) {
        val root = normalizedDirectoryUrl(rootUrl)
        val context = cifsContext(credentials)
        val pending = ArrayDeque<String>().apply { add(root) }
        val visited = mutableSetOf<String>()
        val audioFiles = mutableListOf<SmbRemoteFile>()
        val ebookFiles = mutableListOf<SmbRemoteFile>()

        while (pending.isNotEmpty() && visited.size < 250 && audioFiles.size + ebookFiles.size < 5_000) {
            val dirUrl = normalizedDirectoryUrl(pending.removeFirst())
            if (!visited.add(dirUrl)) continue

            val entries = runCatching { SmbFile(dirUrl, context).listFiles() }.getOrNull().orEmpty()
            entries.forEach { entry ->
                val name = entry.name.trimEnd('/')
                if (name.isBlank() || name == "." || name == "..") return@forEach
                val canonical = entry.canonicalPath
                if (entry.isDirectory) {
                    if (canonical !in visited && pending.size < 1_000) pending.add(canonical)
                    return@forEach
                }

                val ext = name.substringAfterLast('.', "").lowercase()
                val parentName = parentFolderName(canonical)
                val remote = SmbRemoteFile(
                    url = canonical,
                    name = name,
                    parentName = parentName,
                    size = runCatching { entry.length() }.getOrDefault(0L),
                )
                when (ext) {
                    in audioExtensions -> audioFiles += remote
                    in ebookExtensions -> ebookFiles += remote
                }
            }
        }

        val forcedStandaloneIds = groupingOverrides.forcedStandaloneIds(BookSource.SMB, sourceId)
        buildAudioBooks(audioFiles, forcedStandaloneIds) + buildEbookBooks(ebookFiles)
    }

    fun localUrlFor(smbUrl: String, credentials: SmbCredentials, fileName: String): String =
        contentServer.urlFor(smbUrl, credentials, fileName)

    private fun buildAudioBooks(files: List<SmbRemoteFile>, forcedStandaloneIds: Set<String>): List<Book> {
        return files
            .groupBy { it.parentUrl ?: it.url }
            .flatMap { (_, folderFiles) ->
                val groups = AudiobookFileGrouping.groups(
                    files = folderFiles,
                    name = SmbRemoteFile::name,
                    sizeBytes = SmbRemoteFile::size,
                    forcedStandalone = { it.url in forcedStandaloneIds },
                )
                val isCollectionFolder = groups.size > 1
                groups.map { grouped ->
                    val sorted = AudiobookFileGrouping.sorted(grouped, SmbRemoteFile::name)
                    val first = sorted.first()
                    val title = if (isCollectionFolder) {
                        AudiobookFileGrouping.inferredTitle(first.name)
                    } else {
                        first.parentName?.takeIf { it.isNotBlank() }
                            ?: first.name.substringBeforeLast('.').replace('_', ' ')
                    }
                    Book(
                        id = if (isCollectionFolder) first.url else first.parentUrl ?: first.url,
                        title = title.replace('_', ' '),
                        source = BookSource.SMB,
                        mediaType = AppMediaType.AUDIOBOOK,
                        libraryId = "smb-root",
                        libraryName = "SMB Share",
                        hasAudio = true,
                        audioTracks = sorted.mapIndexed { index, file ->
                            AudioTrack(
                                index = index,
                                fileName = file.name,
                                title = file.name.substringBeforeLast('.').replace('_', ' '),
                                durationMs = 0L,
                                fileSizeBytes = file.size,
                                fileId = file.url,
                                contentUrl = file.url,
                            )
                        },
                    )
                }
            }
            .sortedBy { it.title.lowercase() }
    }

    private fun buildEbookBooks(files: List<SmbRemoteFile>): List<Book> {
        return files.map { file ->
            Book(
                id = file.url,
                title = file.name.substringBeforeLast('.').replace('_', ' '),
                source = BookSource.SMB,
                mediaType = AppMediaType.EBOOK,
                libraryId = "smb-root",
                libraryName = "SMB Share",
                hasEbook = true,
            )
        }.sortedBy { it.title.lowercase() }
    }

    private fun cifsContext(credentials: SmbCredentials): CIFSContext {
        val props = Properties().apply {
            setProperty("jcifs.smb.client.enableSMB2", "true")
            setProperty("jcifs.smb.client.disableSMB1", "false")
            setProperty("jcifs.resolveOrder", "DNS")
        }
        val base = BaseContext(PropertyConfiguration(props))
        val auth = NtlmPasswordAuthenticator(credentials.domain, credentials.username, credentials.password)
        return base.withCredentials(auth)
    }

    private fun normalizedDirectoryUrl(url: String): String {
        val trimmed = normalizeSmbUrl(url)
        return if (trimmed.endsWith('/')) trimmed else "$trimmed/"
    }

    private fun normalizeSmbUrl(url: String): String {
        val clean = url.trim()
        if (clean.startsWith("smb://", ignoreCase = true)) return clean
        return "smb://${clean.removePrefix("//")}"
    }

    private fun parentFolderName(url: String): String? {
        val path = Uri.parse(url).path.orEmpty().trim('/')
        val parentPath = path.substringBeforeLast('/', missingDelimiterValue = "")
        return parentPath.substringAfterLast('/').takeIf { it.isNotBlank() }
    }

    private val SmbRemoteFile.parentUrl: String?
        get() = url.substringBeforeLast('/', missingDelimiterValue = "").takeIf { it.startsWith("smb://") }

    private data class SmbRemoteFile(
        val url: String,
        val name: String,
        val parentName: String?,
        val size: Long,
    )

    private inner class SmbContentServer {
        private var server: Server? = null
        private var sessionSecret: String = ""
        private val registry = ConcurrentHashMap<String, SmbStreamEntry>()

        @Synchronized
        fun urlFor(smbUrl: String, credentials: SmbCredentials, fileName: String): String {
            val active = server ?: Server(0).also {
                it.start(NanoHTTPD.SOCKET_READ_TIMEOUT, true)
                server = it
                sessionSecret = UUID.randomUUID().toString().replace("-", "")
            }
            val id = "${smbUrl.hashCode().toUInt().toString(16)}-${registry.size}"
            registry[id] = SmbStreamEntry(smbUrl, credentials, fileName)
            return "http://127.0.0.1:${active.listeningPort}/smb/$sessionSecret/$id/${Uri.encode(fileName)}"
        }

        private inner class Server(port: Int) : NanoHTTPD("127.0.0.1", port) {
            override fun serve(session: IHTTPSession): Response {
                val parts = session.uri.orEmpty().trim('/').split('/', limit = 4)
                if (parts.size < 4 || parts[0] != "smb" || parts[1] != sessionSecret) return forbidden()
                val entry = registry[parts[2]] ?: return notFound()
                return serveRemoteFile(session, entry)
            }

            private fun serveRemoteFile(session: IHTTPSession, entry: SmbStreamEntry): Response {
                return runCatching {
                    val remote = SmbFile(entry.url, cifsContext(entry.credentials))
                    val length = remote.length()
                    val mime = mimeType(entry.fileName)
                    val rangeHeader = session.headers["range"]
                    if (rangeHeader.isNullOrBlank() || !rangeHeader.startsWith("bytes=", ignoreCase = true)) {
                        newFixedLengthResponse(Response.Status.OK, mime, remote.inputStream, length).apply {
                            addHeader("Accept-Ranges", "bytes")
                        }
                    } else {
                        val spec = rangeHeader.substring(6).split('-', limit = 2)
                        val start = spec.getOrNull(0)?.toLongOrNull() ?: 0L
                        val end = spec.getOrNull(1)?.takeIf { it.isNotBlank() }?.toLongOrNull() ?: (length - 1L)
                        val clampedEnd = min(end, length - 1L)
                        val clampedStart = max(0L, min(start, clampedEnd))
                        val contentLength = clampedEnd - clampedStart + 1L
                        val stream = remote.inputStream.positionedAt(clampedStart)
                        newFixedLengthResponse(Response.Status.PARTIAL_CONTENT, mime, stream, contentLength).apply {
                            addHeader("Content-Range", "bytes $clampedStart-$clampedEnd/$length")
                            addHeader("Accept-Ranges", "bytes")
                        }
                    }
                }.getOrElse {
                    newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "SMB stream failed")
                }
            }

            private fun forbidden(): Response =
                newFixedLengthResponse(Response.Status.FORBIDDEN, "text/plain", "Forbidden")

            private fun notFound(): Response =
                newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "Not Found")
        }

        private fun InputStream.positionedAt(offset: Long): InputStream {
            var remaining = offset
            while (remaining > 0) {
                val skipped = skip(remaining)
                if (skipped <= 0) break
                remaining -= skipped
            }
            return this
        }

        private fun mimeType(fileName: String): String = when (fileName.substringAfterLast('.', "").lowercase()) {
            "epub" -> "application/epub+zip"
            "pdf" -> "application/pdf"
            "cbz" -> "application/vnd.comicbook+zip"
            "cbr" -> "application/vnd.comicbook-rar"
            else -> AudioPlaybackManager.guessMimeType(fileName)
        }
    }

    private data class SmbStreamEntry(
        val url: String,
        val credentials: SmbCredentials,
        val fileName: String,
    )
}
