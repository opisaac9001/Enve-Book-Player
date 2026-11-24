package com.enve.app.data.offline

import android.content.Context
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.StandardCopyOption
import java.nio.file.Files
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ComicOfflineStorage(
    locations: ProfileStorageLocations,
) {
    private val profileId = locations.profileId
    private val sharedDownloadsDirectory = locations.sharedDownloadsDirectory
    @Inject
    constructor(@ApplicationContext context: Context) : this(
        ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
    )

    private val rootDir = File(locations.filesDirectory, "offline-comics").also {
        if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) {
            it.mkdirs()
        } else {
            check(it.isDirectory || it.mkdirs())
            check(it.canRead() && it.canWrite())
        }
    }

    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }

    private val pendingDirectory = File(rootDir, ".pending").also { check(it.isDirectory || it.mkdirs()) }

    @Volatile private var indexedDirectories: Map<String, String>? = null

    init {
        CompletedDownloadImporter.recover(sharedDownloadsDirectory)
        migratePendingRequests()
    }

    private fun migratePendingRequests() {
        pendingDirectory.listFiles().orEmpty().filter { it.extension == "json" }.forEach { file ->
            val book = runCatching { json.decodeFromString<Book>(file.readText()) }.getOrNull() ?: return@forEach
            if (file.nameWithoutExtension == book.offlineDownloadKey) return@forEach
            if (!File(pendingDirectory, "${book.offlineDownloadKey}.json").exists()) savePendingRequest(book)
            android.util.AtomicFile(file).delete()
        }
    }

    private fun downloadDirectories(): List<File> =
        rootDir.listFiles().orEmpty().filter { it.isDirectory && !it.name.startsWith(".") }

    private fun decodeManifest(dir: File): Book? {
        val file = File(dir, "book.json")
        if (!file.exists()) return null
        return runCatching { json.decodeFromString<Book>(file.readText()) }.getOrNull()
    }

    private fun readManifest(dir: File): Book? {
        val manifest = decodeManifest(dir)
        if (manifest != null && !isRecovered(dir, manifest)) return manifest
        val file = dir.listFiles().orEmpty().firstOrNull { it.isCommittedBookFile() }
        if (manifest == null && (file == null || dir.name.startsWith("dl-") || offlineDownloadKey(BookSource.LOCAL, null, dir.name) == dir.name)) {
            return null
        }
        return Book(
            id = recoveredLocalBookId("ebook", dir.name),
            title = manifest?.title ?: dir.name,
            author = manifest?.author,
            coverUrl = manifest?.coverUrl?.takeIf { it.startsWith("file:") },
            source = BookSource.LOCAL,
            mediaType = AppMediaType.EBOOK,
            primaryFileType = manifest?.primaryFileType ?: file?.extension,
            readAlongAvailable = manifest?.readAlongAvailable == true,
            hasEbook = true,
            hasAudio = manifest?.hasAudio == true,
            isDownloaded = true,
        )
    }

    private fun isRecovered(dir: File, manifest: Book): Boolean =
        manifest.source != BookSource.LOCAL && manifest.connectionId == null && dir.name == legacyOfflineDirectoryName(manifest.id)

    private fun indexed(): Map<String, String> = indexedDirectories ?: downloadDirectories()
        .mapNotNull { dir -> readManifest(dir)?.offlineDownloadKey?.takeIf { it != dir.name }?.let { it to dir.name } }
        .toMap()
        .also { indexedDirectories = it }

    private fun bookDirectory(key: String): File {
        require(SAFE_SEGMENT.matches(key))
        return File(rootDir, indexed()[key] ?: key)
    }

    private fun keyOf(dir: File): String = readManifest(dir)?.offlineDownloadKey ?: dir.name

    private fun legacySourceBookId(key: String): String? {
        val dir = bookDirectory(key)
        return decodeManifest(dir)?.id?.takeIf { dir.name == legacyOfflineDirectoryName(it) }
    }

    fun savePendingRequest(book: Book) {
        val atomic = android.util.AtomicFile(File(pendingDirectory, "${book.offlineDownloadKey}.json"))
        val output = atomic.startWrite()
        try {
            output.write(json.encodeToString(book).toByteArray())
            atomic.finishWrite(output)
        } catch (error: Exception) {
            atomic.failWrite(output)
            throw error
        }
    }

    fun listPendingRequests(): List<Book> = pendingDirectory.listFiles().orEmpty()
        .filter { it.extension == "json" }
        .mapNotNull { runCatching { json.decodeFromString<Book>(it.readText()) }.getOrNull() }

    fun hasPendingRequest(key: String): Boolean {
        require(SAFE_SEGMENT.matches(key))
        return File(pendingDirectory, "$key.json").isFile
    }

    fun clearPendingRequest(key: String) {
        require(SAFE_SEGMENT.matches(key))
        android.util.AtomicFile(File(pendingDirectory, "$key.json")).delete()
    }

    fun isDownloaded(key: String): Boolean {
        val dir = bookDirectory(key)
        if (!dir.exists()) return false
        return dir.listFiles().orEmpty().any { it.isCommittedBookFile() }
    }

    fun getDownloadedFile(key: String): File? {
        val dir = bookDirectory(key)
        if (!dir.exists()) return null
        return dir.listFiles().orEmpty().firstOrNull { it.isCommittedBookFile() }
    }

    fun createTempFile(key: String, extension: String): File {
        val dir = bookDirectory(key).also { it.mkdirs() }
        val ext = extension.lowercase().ifBlank { "bin" }
        return File(dir, "book.$ext.part")
    }

    fun existingTempFile(key: String): File? {
        val dir = bookDirectory(key)
        if (!dir.exists()) return null
        return dir.listFiles()?.firstOrNull {
            it.isFile && it.name.startsWith("book.") && it.name.endsWith(".part") && it.length() > 0L
        }
    }

    fun resumeValidatorFile(key: String): File = File(bookDirectory(key), ".resume-validator")

    fun commit(temp: File): File {
        val final = File(temp.parentFile, temp.name.removeSuffix(".part"))
        check(temp.renameTo(final)) { "Could not commit the completed book" }
        return final
    }

    fun saveManifest(book: Book) {
        require(!isRecoveredLocalBookId(book.id))
        val dir = bookDirectory(book.offlineDownloadKey).also { it.mkdirs() }
        val staged = File(dir, ".book-manifest.tmp")
        staged.outputStream().use { output ->
            output.write(json.encodeToString(book).toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        Files.move(staged.toPath(), File(dir, "book.json").toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        indexedDirectories = null
    }

    fun getManifest(key: String): Book? = readManifest(bookDirectory(key))

    fun listManifests(): List<Book> =
        downloadDirectories().filter(::isDownloadedDir).mapNotNull(::readManifest)

    fun removeDownload(key: String) {
        val dir = bookDirectory(key)
        val legacyBookId = decodeManifest(dir)?.id?.takeIf { dir.name == legacyOfflineDirectoryName(it) }
        CompletedDownloadImporter.revoke(sharedDownloadsDirectory, profileId, key, "ebook")
        if (legacyBookId != null && legacyBookId != key) {
            CompletedDownloadImporter.revoke(sharedDownloadsDirectory, profileId, legacyBookId, "ebook")
        }
        clearPendingRequest(key)
        check(!dir.exists() || dir.deleteRecursively())
        indexedDirectories = null
        collectUnusedSharedDownloads()
    }

    fun listDownloadedKeys(): Set<String> =
        downloadDirectories().filter(::isDownloadedDir).map(::keyOf).toSet()

    private fun isDownloadedDir(dir: File): Boolean =
        dir.listFiles().orEmpty().any { it.isCommittedBookFile() }

    private fun File.isCommittedBookFile(): Boolean =
        isFile && name.startsWith("book.") && name != "book.json" && !name.endsWith(".part") && length() > 0L &&
            runCatching { CompletedDownloadImporter.resolve(sharedDownloadsDirectory, profileId, "ebook", rootDir, this) }.isSuccess

    fun collectUnusedSharedDownloads(): Long = CompletedDownloadImporter.collectUnused(sharedDownloadsDirectory)

    fun sharedStorageBytes(): Long = CompletedDownloadImporter.physicalBytes(sharedDownloadsDirectory)

    fun coverFile(key: String): File = File(bookDirectory(key).also { check(it.isDirectory || it.mkdirs()) }, "cover.img")

    fun importedBookId(source: ComicOfflineStorage, sourceKey: String): String? {
        fun find(sourceBookId: String) =
            CompletedDownloadImporter.findImported(sharedDownloadsDirectory, rootDir, profileId, source.profileId, sourceBookId, "ebook")
        return (find(sourceKey) ?: source.legacySourceBookId(sourceKey)?.takeIf { it != sourceKey }?.let(::find))?.name
    }

    fun importCompletedDownload(source: ComicOfflineStorage, sourceKey: String, beforePublish: () -> Unit = {}): Book {
        require(source.profileId != profileId)
        require(source.sharedDownloadsDirectory == sharedDownloadsDirectory)
        val book = requireNotNull(source.getManifest(sourceKey))
        require(book.offlineDownloadKey == sourceKey)
        importedBookId(source, sourceKey)?.let { return requireNotNull(getManifest(it)) }
        val payload = requireNotNull(source.getDownloadedFile(sourceKey))
        val extension = payload.extension
        val readAlong = (extension.equals("epub", true) || extension.equals("kepub", true)) && hasEmbeddedReadAloud(payload)
        val cover = source.coverFile(sourceKey).takeIf { it.isFile && it.length() > 0L }
        val payloads = listOf(CompletedDownloadFile(payload, "book.$extension")) +
            listOfNotNull(cover?.let { CompletedDownloadFile(it, "cover.img", it.length()) })
        val directory = CompletedDownloadImporter.importCompleted(
            shared = sharedDownloadsDirectory,
            sourceRoot = source.rootDir,
            sourceProfileId = source.profileId,
            sourceBookId = sourceKey,
            format = "ebook",
            destinationRoot = rootDir,
            destinationProfileId = profileId,
            beforePublish = beforePublish,
            files = payloads,
        ) { localId, stage ->
            val imported = Book(
                id = localId,
                title = book.title,
                author = book.author,
                coverUrl = cover?.let { android.net.Uri.fromFile(File(rootDir, "$localId/cover.img")).toString() },
                readAlongAvailable = readAlong,
                source = BookSource.LOCAL,
                mediaType = AppMediaType.EBOOK,
                primaryFileType = extension,
                isDownloaded = true,
                hasEbook = true,
            )
            File(stage, "book.json").writeText(json.encodeToString(imported))
        }
        indexedDirectories = null
        return requireNotNull(getManifest(directory.name)).also {
            check(it.source == BookSource.LOCAL && isDownloaded(it.offlineDownloadKey))
        }
    }
    private fun hasEmbeddedReadAloud(file: File): Boolean = runCatching {
        java.util.zip.ZipFile(file).use { zip ->
            fun xml(path: String, visit: (org.xmlpull.v1.XmlPullParser) -> Unit) {
                val entry = requireNotNull(zip.getEntry(path))
                require(!entry.isDirectory && entry.size in 1..4_194_304L)
                zip.getInputStream(entry).use { input ->
                    val parser = android.util.Xml.newPullParser()
                    parser.setInput(input, null)
                    while (parser.next() != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
                        if (parser.eventType == org.xmlpull.v1.XmlPullParser.START_TAG) visit(parser)
                    }
                }
            }
            fun resolve(base: String, href: String): String {
                val uri = java.net.URI(href)
                require(!uri.isAbsolute && uri.rawAuthority == null && uri.rawQuery == null)
                val relative = java.nio.file.Paths.get(uri.path)
                require(!relative.isAbsolute)
                val result = java.nio.file.Paths.get(base).resolve(relative).normalize()
                require(!result.startsWith(".."))
                return result.toString().replace(File.separatorChar, '/')
            }
            var packagePath: String? = null
            xml("META-INF/container.xml") { parser ->
                if (parser.name.substringAfterLast(':') == "rootfile") packagePath = parser.getAttributeValue(null, "full-path")
            }
            val opf = resolve("", requireNotNull(packagePath))
            val items = mutableMapOf<String, Triple<String, String?, String?>>()
            val spine = mutableListOf<String>()
            xml(opf) { parser ->
                when (parser.name.substringAfterLast(':')) {
                    "item" -> items[requireNotNull(parser.getAttributeValue(null, "id"))] = Triple(
                        requireNotNull(parser.getAttributeValue(null, "href")),
                        parser.getAttributeValue(null, "media-type"), parser.getAttributeValue(null, "media-overlay"),
                    )
                    "itemref" -> spine += requireNotNull(parser.getAttributeValue(null, "idref"))
                }
            }
            val overlays = spine.mapNotNull { items[it]?.third }.distinct().map { requireNotNull(items[it]) }
            require(overlays.isNotEmpty())
            overlays.all { overlay ->
                require(overlay.second == "application/smil+xml")
                val smil = resolve(opf.substringBeforeLast('/', ""), overlay.first)
                var audioCount = 0
                xml(smil) { parser ->
                    if (parser.name.substringAfterLast(':') == "audio") {
                        val path = resolve(smil.substringBeforeLast('/', ""), requireNotNull(parser.getAttributeValue(null, "src")))
                        val audio = requireNotNull(zip.getEntry(path))
                        require(!audio.isDirectory && audio.size > 0L)
                        audioCount++
                    }
                }
                audioCount > 0
            }
        }
    }.getOrDefault(false)

    private companion object {
        val SAFE_SEGMENT = Regex("[A-Za-z0-9_-]{1,255}")
    }
}
