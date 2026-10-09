package com.enve.app.data.offline

import android.content.Context
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OfflineAudioStorage(
    locations: ProfileStorageLocations,
) {
    private val profileId = locations.profileId
    private val sharedDownloadsDirectory = locations.sharedDownloadsDirectory
    @Inject
    constructor(@ApplicationContext context: Context) : this(
        ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
    )

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
    }

    private val rootDir = File(locations.filesDirectory, "offline-audio").also {
        if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) {
            it.mkdirs()
        } else {
            check(it.isDirectory || it.mkdirs())
            check(it.canRead() && it.canWrite())
        }
    }

    private val pendingDir = File(rootDir, ".pending").also {
        if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) {
            it.mkdirs()
        } else {
            check(it.isDirectory || it.mkdirs())
            check(it.canRead() && it.canWrite())
        }
    }

    init {
        CompletedDownloadImporter.recover(sharedDownloadsDirectory)
    }

    private fun safeId(bookId: String): String =
        bookId.replace(Regex("[^a-zA-Z0-9_-]"), "_")

    fun savePendingRequest(book: Book) {
        File(pendingDir, "${safeId(book.id)}.json").writeText(json.encodeToString(book))
    }

    fun getPendingRequest(bookId: String): Book? {
        val file = File(pendingDir, "${safeId(bookId)}.json")
        if (!file.exists()) return null
        return runCatching { json.decodeFromString<Book>(file.readText()) }.getOrNull()
    }

    fun listPendingRequests(): List<Book> =
        pendingDir.listFiles()?.filter { it.extension == "json" }.orEmpty()
            .mapNotNull { runCatching { json.decodeFromString<Book>(it.readText()) }.getOrNull() }

    fun clearPendingRequest(bookId: String) {
        File(pendingDir, "${safeId(bookId)}.json").delete()
    }

    fun bookDirectory(bookId: String): File = File(rootDir, safeId(bookId))

    fun createTrackTempFile(bookId: String, trackIndex: Int): File {
        val dir = bookDirectory(bookId).also { it.mkdirs() }
        return File(dir, "track_${trackIndex}.part")
    }

    fun createTrackFinalFile(bookId: String, trackIndex: Int, extension: String): File {
        val dir = bookDirectory(bookId).also { it.mkdirs() }
        return File(dir, "track_${trackIndex}.${extension.ifBlank { "bin" }}")
    }

    fun existingTrackFinalFile(bookId: String, trackIndex: Int): File? {
        val dir = bookDirectory(bookId)
        if (!dir.exists()) return null
        return dir.listFiles()?.firstOrNull {
            it.isFile &&
                it.name.startsWith("track_${trackIndex}.") &&
                !it.name.endsWith(".part") &&
                it.length() > 0L &&
                runCatching { CompletedDownloadImporter.resolve(sharedDownloadsDirectory, profileId, "audio", rootDir, it) }.isSuccess
        }
    }

    fun coverFile(bookId: String): File =
        File(bookDirectory(bookId).also { it.mkdirs() }, "cover.img")

    fun relativePath(file: File): String =
        file.relativeTo(rootDir).invariantSeparatorsPath

    fun absolutePath(relativePath: String): File {
        require(!File(relativePath).isAbsolute)
        return CompletedDownloadImporter.resolve(sharedDownloadsDirectory, profileId, "audio", rootDir, File(rootDir, relativePath))
    }

    fun saveManifest(manifest: OfflineAudioManifest) {
        val dir = bookDirectory(manifest.bookId).also { it.mkdirs() }
        File(dir, "manifest.json").writeText(json.encodeToString(manifest))
    }

    fun getManifest(bookId: String): OfflineAudioManifest? {
        val file = File(bookDirectory(bookId), "manifest.json")
        if (!file.exists()) return null
        return runCatching {
            json.decodeFromString<OfflineAudioManifest>(file.readText())
        }.getOrNull()
    }

    fun listManifests(): List<OfflineAudioManifest> {
        val dirs = rootDir.listFiles()?.filter { it.isDirectory && !it.name.startsWith(".") }.orEmpty()
        return dirs.mapNotNull { dir ->
            val file = File(dir, "manifest.json")
            if (!file.exists()) return@mapNotNull null
            runCatching { json.decodeFromString<OfflineAudioManifest>(file.readText()) }.getOrNull()
        }.sortedByDescending { it.downloadedAtEpochMs }
    }

    fun isDownloaded(bookId: String): Boolean {
        val manifest = getManifest(bookId) ?: return false
        return manifest.tracks.isNotEmpty() && manifest.tracks.all { absolutePath(it.relativePath).exists() }
    }

    fun removeDownload(bookId: String) {
        CompletedDownloadImporter.revoke(sharedDownloadsDirectory, profileId, bookId, "audio")
        check(!bookDirectory(bookId).exists() || bookDirectory(bookId).deleteRecursively())
        collectUnusedSharedDownloads()
    }

    fun collectUnusedSharedDownloads(): Long = CompletedDownloadImporter.collectUnused(sharedDownloadsDirectory)

    fun sharedStorageBytes(): Long = CompletedDownloadImporter.physicalBytes(sharedDownloadsDirectory)

    fun importedBookId(sourceProfileId: String, sourceBookId: String): String? =
        CompletedDownloadImporter.findImported(sharedDownloadsDirectory, rootDir, profileId, sourceProfileId, sourceBookId, "audio")?.name

    fun importCompletedDownload(source: OfflineAudioStorage, bookId: String, beforePublish: () -> Unit = {}): OfflineAudioManifest {
        require(source.profileId != profileId)
        require(source.sharedDownloadsDirectory == sharedDownloadsDirectory)
        val manifest = requireNotNull(source.getManifest(bookId))
        require(manifest.bookId == bookId && manifest.tracks.isNotEmpty())
        require(manifest.tracks.all { it.index >= 0 && it.durationMs >= 0L })
        require(manifest.tracks.map { it.index }.distinct().size == manifest.tracks.size)
        val tracks = manifest.tracks.map { track ->
            require(!File(track.relativePath).isAbsolute && !track.relativePath.endsWith(".part"))
            val file = File(source.rootDir, track.relativePath)
            CompletedDownloadFile(
                source = file,
                destinationName = "track_${track.index}.${file.extension.ifBlank { "bin" }}",
                expectedBytes = track.bytes,
            )
        }
        val cover = source.coverFile(bookId).takeIf { it.isFile && it.length() > 0L }
        val payloads = tracks + listOfNotNull(cover?.let { CompletedDownloadFile(it, "cover.img", it.length()) })
        val directory = CompletedDownloadImporter.importCompleted(
            shared = sharedDownloadsDirectory,
            sourceRoot = source.rootDir,
            sourceProfileId = source.profileId,
            sourceBookId = bookId,
            format = "audio",
            destinationRoot = rootDir,
            destinationProfileId = profileId,
            beforePublish = beforePublish,
            files = payloads,
        ) { localId, stage ->
            val imported = OfflineAudioManifest(
                bookId = localId,
                title = manifest.title,
                author = manifest.author,
                coverUrl = cover?.let { android.net.Uri.fromFile(File(rootDir, "$localId/cover.img")).toString() },
                source = BookSource.LOCAL.name,
                downloadedAtEpochMs = System.currentTimeMillis(),
                tracks = manifest.tracks.zip(tracks).map { (track, payload) ->
                    OfflineAudioTrackManifest(
                        index = track.index,
                        title = track.title,
                        durationMs = track.durationMs,
                        relativePath = "$localId/${payload.destinationName}",
                        bytes = File(stage, payload.destinationName).length(),
                    )
                },
            )
            File(stage, "manifest.json").writeText(json.encodeToString(imported))
        }
        return requireNotNull(getManifest(directory.name)).also {
            check(it.source == BookSource.LOCAL.name && isDownloaded(it.bookId))
        }
    }
}
