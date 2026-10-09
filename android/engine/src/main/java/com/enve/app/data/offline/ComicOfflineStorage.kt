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

    init {
        CompletedDownloadImporter.recover(sharedDownloadsDirectory)
    }

    private fun safeId(bookId: String): String = bookId.replace(Regex("[^a-zA-Z0-9_-]"), "_")

    private fun bookDirectory(bookId: String): File = File(rootDir, safeId(bookId))

    private val pendingDirectory = File(rootDir, ".pending").also { check(it.isDirectory || it.mkdirs()) }

    fun savePendingRequest(book: Book) {
        val atomic = android.util.AtomicFile(File(pendingDirectory, "${safeId(book.id)}.json"))
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
        .filter { it.extension == "json" }.map { json.decodeFromString<Book>(it.readText()) }

    fun clearPendingRequest(bookId: String) {
        android.util.AtomicFile(File(pendingDirectory, "${safeId(bookId)}.json")).delete()
    }

    fun isDownloaded(bookId: String): Boolean {
        val dir = bookDirectory(bookId)
        if (!dir.exists()) return false
        return dir.listFiles().orEmpty().any { it.isCommittedBookFile() }
    }

    fun getDownloadedFile(bookId: String): File? {
        val dir = bookDirectory(bookId)
        if (!dir.exists()) return null
        return dir.listFiles().orEmpty().firstOrNull { it.isCommittedBookFile() }
    }

    fun createTempFile(bookId: String, extension: String): File {
        val dir = bookDirectory(bookId).also { it.mkdirs() }
        val ext = extension.lowercase().ifBlank { "bin" }
        return File(dir, "book.$ext.part")
    }

    fun existingTempFile(bookId: String): File? {
        val dir = bookDirectory(bookId)
        if (!dir.exists()) return null
        return dir.listFiles()?.firstOrNull {
            it.isFile && it.name.startsWith("book.") && it.name.endsWith(".part") && it.length() > 0L
        }
    }

    fun commit(temp: File): File {
        val final = File(temp.parentFile, temp.name.removeSuffix(".part"))
        if (final.exists()) check(final.delete())
        if (!temp.renameTo(final)) {
            temp.copyTo(final)
            temp.delete()
        }
        return final
    }

    fun saveManifest(book: Book) {
        val dir = bookDirectory(book.id).also { it.mkdirs() }
        File(dir, "book.json").writeText(json.encodeToString(book))
    }

    fun getManifest(bookId: String): Book? {
        val file = File(bookDirectory(bookId), "book.json")
        if (!file.exists()) return null
        return runCatching { json.decodeFromString<Book>(file.readText()) }.getOrNull()
    }

    fun listManifests(): List<Book> =
        rootDir.listFiles().orEmpty()
            .filter { it.isDirectory && !it.name.startsWith(".") && isDownloadedDir(it) }
            .mapNotNull { dir ->
                val file = File(dir, "book.json")
                if (!file.exists()) null
                else runCatching { json.decodeFromString<Book>(file.readText()) }.getOrNull()
            }

    fun removeDownload(bookId: String) {
        CompletedDownloadImporter.revoke(sharedDownloadsDirectory, profileId, bookId, "ebook")
        clearPendingRequest(bookId)
        check(!bookDirectory(bookId).exists() || bookDirectory(bookId).deleteRecursively())
        collectUnusedSharedDownloads()
    }

    fun listDownloadedBookIds(): Set<String> {
        return rootDir.listFiles().orEmpty()
            .filter { it.isDirectory && !it.name.startsWith(".") && isDownloadedDir(it) }
            .mapNotNull { dir ->

                getManifest(dir.name)?.id ?: dir.name
            }
            .toSet()
    }

    private fun isDownloadedDir(dir: File): Boolean =
        dir.listFiles().orEmpty().any { it.isCommittedBookFile() }

    private fun File.isCommittedBookFile(): Boolean =
        isFile && name.startsWith("book.") && name != "book.json" && !name.endsWith(".part") && length() > 0L &&
            runCatching { CompletedDownloadImporter.resolve(sharedDownloadsDirectory, profileId, "ebook", rootDir, this) }.isSuccess

    fun collectUnusedSharedDownloads(): Long = CompletedDownloadImporter.collectUnused(sharedDownloadsDirectory)

    fun sharedStorageBytes(): Long = CompletedDownloadImporter.physicalBytes(sharedDownloadsDirectory)

    fun coverFile(bookId: String): File = File(bookDirectory(bookId).also { check(it.isDirectory || it.mkdirs()) }, "cover.img")

    fun importedBookId(sourceProfileId: String, sourceBookId: String): String? =
        CompletedDownloadImporter.findImported(sharedDownloadsDirectory, rootDir, profileId, sourceProfileId, sourceBookId, "ebook")?.name

    fun importCompletedDownload(source: ComicOfflineStorage, bookId: String, beforePublish: () -> Unit = {}): Book {
        require(source.profileId != profileId)
        require(source.sharedDownloadsDirectory == sharedDownloadsDirectory)
        val book = requireNotNull(source.getManifest(bookId))
        require(book.id == bookId)
        val payload = requireNotNull(source.getDownloadedFile(bookId))
        val extension = payload.extension
        val readAlong = extension.equals("epub", true) && hasEmbeddedReadAloud(payload)
        val cover = source.coverFile(bookId).takeIf { it.isFile && it.length() > 0L }
        val payloads = listOf(CompletedDownloadFile(payload, "book.$extension")) +
            listOfNotNull(cover?.let { CompletedDownloadFile(it, "cover.img", it.length()) })
        val directory = CompletedDownloadImporter.importCompleted(
            shared = sharedDownloadsDirectory,
            sourceRoot = source.rootDir,
            sourceProfileId = source.profileId,
            sourceBookId = bookId,
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
        return requireNotNull(getManifest(directory.name)).also {
            check(it.source == BookSource.LOCAL && isDownloaded(it.id))
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

}
