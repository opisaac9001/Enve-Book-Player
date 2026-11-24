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
import java.nio.file.Files
import java.nio.file.StandardCopyOption
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

    @Volatile private var claimedDirectories: Map<String, String>? = null

    init {
        CompletedDownloadImporter.recover(sharedDownloadsDirectory)
        migratePendingRequests()
    }

    private fun migratePendingRequests() {
        pendingDir.listFiles()?.filter { it.extension == "json" }.orEmpty().forEach { file ->
            val book = runCatching { json.decodeFromString<Book>(file.readText()) }.getOrNull() ?: return@forEach
            if (file.nameWithoutExtension == book.offlineDownloadKey) return@forEach
            val target = File(pendingDir, "${book.offlineDownloadKey}.json")
            if (!target.exists()) target.writeText(json.encodeToString(book))
            file.delete()
        }
    }

    private fun claimed(): Map<String, String> = claimedDirectories ?: downloadDirectories()
        .mapNotNull { dir -> readManifest(dir)?.downloadKey?.takeIf { it != dir.name }?.let { it to dir.name } }
        .toMap()
        .also { claimedDirectories = it }

    private fun downloadDirectories(): List<File> =
        rootDir.listFiles()?.filter { it.isDirectory && !it.name.startsWith(".") }.orEmpty()

    private fun decodeManifest(dir: File): OfflineAudioManifest? {
        val file = File(dir, "manifest.json")
        if (!file.exists()) return null
        return runCatching { json.decodeFromString<OfflineAudioManifest>(file.readText()) }.getOrNull()
    }

    private fun readManifest(dir: File): OfflineAudioManifest? {
        val manifest = decodeManifest(dir) ?: return null
        if (!isRecovered(dir, manifest)) return manifest.copy(downloadKey = manifest.downloadKey.ifEmpty { dir.name })
        val id = recoveredLocalBookId("audio", dir.name)
        return manifest.copy(
            bookId = id,
            coverUrl = manifest.coverUrl?.takeIf { it.startsWith("file:") },
            source = BookSource.LOCAL.name,
            connectionId = null,
            downloadKey = offlineDownloadKey(BookSource.LOCAL, null, id),
        )
    }

    private fun isRecovered(dir: File, manifest: OfflineAudioManifest): Boolean =
        manifest.downloadKey.isEmpty() &&
            !(manifest.source == BookSource.LOCAL.name && offlineDownloadKey(BookSource.LOCAL, null, manifest.bookId) == dir.name)

    private fun legacySourceBookId(key: String): String? {
        val dir = bookDirectory(key)
        val manifest = decodeManifest(dir) ?: return null
        return manifest.bookId.takeIf { manifest.downloadKey.isEmpty() && dir.name == legacyOfflineDirectoryName(it) }
    }

    fun savePendingRequest(book: Book) {
        File(pendingDir, "${book.offlineDownloadKey}.json").writeText(json.encodeToString(book))
    }

    fun getPendingRequest(key: String): Book? {
        val file = File(pendingDir, "${checkedKey(key)}.json")
        if (!file.exists()) return null
        return runCatching { json.decodeFromString<Book>(file.readText()) }.getOrNull()
    }

    fun listPendingRequests(): List<Book> =
        pendingDir.listFiles()?.filter { it.extension == "json" }.orEmpty()
            .mapNotNull { runCatching { json.decodeFromString<Book>(it.readText()) }.getOrNull() }

    fun clearPendingRequest(key: String) {
        File(pendingDir, "${checkedKey(key)}.json").delete()
    }

    fun bookDirectory(key: String): File = File(rootDir, claimed()[checkedKey(key)] ?: key)

    fun createTrackTempFile(key: String, trackIndex: Int): File {
        val dir = bookDirectory(key).also { it.mkdirs() }
        return File(dir, "track_${trackIndex}.part")
    }

    fun trackResumeValidatorFile(key: String, trackIndex: Int): File {
        val dir = bookDirectory(key).also { it.mkdirs() }
        return File(dir, "resume_${trackIndex}.validator")
    }

    fun trackAssetFile(key: String, trackIndex: Int): File {
        val dir = bookDirectory(key).also { it.mkdirs() }
        return File(dir, "asset_${trackIndex}.id")
    }

    fun createTrackFinalFile(key: String, trackIndex: Int, extension: String): File {
        val dir = bookDirectory(key).also { it.mkdirs() }
        return File(dir, "track_${trackIndex}.${extension.ifBlank { "bin" }}")
    }

    fun existingTrackFinalFile(key: String, trackIndex: Int): File? {
        val dir = bookDirectory(key)
        if (!dir.exists()) return null
        return dir.listFiles()?.firstOrNull {
            it.isFile &&
                it.name.startsWith("track_${trackIndex}.") &&
                !it.name.endsWith(".part") &&
                it.length() > 0L &&
                runCatching { CompletedDownloadImporter.resolve(sharedDownloadsDirectory, profileId, "audio", rootDir, it) }.isSuccess
        }
    }

    fun coverFile(key: String): File =
        File(bookDirectory(key).also { it.mkdirs() }, "cover.img")

    fun relativePath(file: File): String =
        file.relativeTo(rootDir).invariantSeparatorsPath

    fun absolutePath(relativePath: String): File {
        require(!File(relativePath).isAbsolute)
        return CompletedDownloadImporter.resolve(sharedDownloadsDirectory, profileId, "audio", rootDir, File(rootDir, relativePath))
    }

    fun saveManifest(manifest: OfflineAudioManifest) {
        require(manifest.downloadKey.isNotEmpty() && !isRecoveredLocalBookId(manifest.bookId))
        val dir = bookDirectory(manifest.downloadKey).also { it.mkdirs() }
        writeManifest(dir, manifest)
    }

    private fun writeManifest(dir: File, manifest: OfflineAudioManifest) {
        val staged = File(dir, "manifest.json.tmp")
        staged.outputStream().use { output ->
            output.write(json.encodeToString(manifest).toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        Files.move(
            staged.toPath(),
            File(dir, "manifest.json").toPath(),
            StandardCopyOption.ATOMIC_MOVE,
            StandardCopyOption.REPLACE_EXISTING,
        )
        claimedDirectories = null
    }

    fun getManifest(key: String): OfflineAudioManifest? = readManifest(bookDirectory(key))

    fun listManifests(): List<OfflineAudioManifest> =
        downloadDirectories().mapNotNull(::readManifest).sortedByDescending { it.downloadedAtEpochMs }

    fun isDownloaded(key: String): Boolean {
        val manifest = getManifest(key) ?: return false
        return manifest.tracks.isNotEmpty() && manifest.tracks.all { track ->
            val file = absolutePath(track.relativePath)
            val length = file.length()
            file.isFile && length > 0 && (track.bytes <= 0 || length == track.bytes)
        }
    }

    fun discardPartialDownload(key: String) {
        val dir = bookDirectory(key)
        if (!dir.exists()) return
        if (!isDownloaded(key)) return removeDownload(key)
        dir.listFiles()
            ?.filter { it.isFile && (it.name.endsWith(".part") || it.name.endsWith(".validator")) }
            ?.forEach { check(it.delete()) }
    }

    fun removeDownload(key: String) {
        val dir = bookDirectory(key)
        val legacyBookId = decodeManifest(dir)?.bookId?.takeIf { dir.name == legacyOfflineDirectoryName(it) }
        CompletedDownloadImporter.revoke(sharedDownloadsDirectory, profileId, key, "audio")
        if (legacyBookId != null && legacyBookId != key) {
            CompletedDownloadImporter.revoke(sharedDownloadsDirectory, profileId, legacyBookId, "audio")
        }
        check(!dir.exists() || dir.deleteRecursively())
        claimedDirectories = null
        collectUnusedSharedDownloads()
    }

    fun collectUnusedSharedDownloads(): Long = CompletedDownloadImporter.collectUnused(sharedDownloadsDirectory)

    fun sharedStorageBytes(): Long = CompletedDownloadImporter.physicalBytes(sharedDownloadsDirectory)

    fun importedBookId(source: OfflineAudioStorage, sourceKey: String): String? {
        fun find(sourceBookId: String) =
            CompletedDownloadImporter.findImported(sharedDownloadsDirectory, rootDir, profileId, source.profileId, sourceBookId, "audio")
        return (find(sourceKey) ?: source.legacySourceBookId(sourceKey)?.takeIf { it != sourceKey }?.let(::find))?.name
    }

    fun importCompletedDownload(source: OfflineAudioStorage, sourceKey: String, beforePublish: () -> Unit = {}): OfflineAudioManifest {
        require(source.profileId != profileId)
        require(source.sharedDownloadsDirectory == sharedDownloadsDirectory)
        val manifest = requireNotNull(source.getManifest(sourceKey))
        require(manifest.downloadKey == sourceKey && manifest.tracks.isNotEmpty())
        importedBookId(source, sourceKey)?.let { return requireNotNull(getManifest(it)) }
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
        val cover = source.coverFile(sourceKey).takeIf { it.isFile && it.length() > 0L }
        val payloads = tracks + listOfNotNull(cover?.let { CompletedDownloadFile(it, "cover.img", it.length()) })
        val directory = CompletedDownloadImporter.importCompleted(
            shared = sharedDownloadsDirectory,
            sourceRoot = source.rootDir,
            sourceProfileId = source.profileId,
            sourceBookId = sourceKey,
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
                downloadKey = offlineDownloadKey(BookSource.LOCAL, null, localId),
            )
            File(stage, "manifest.json").writeText(json.encodeToString(imported))
        }
        claimedDirectories = null
        return requireNotNull(getManifest(directory.name)).also {
            check(it.source == BookSource.LOCAL.name && isDownloaded(it.downloadKey))
        }
    }

    private fun checkedKey(key: String): String = key.also { require(SAFE_SEGMENT.matches(it)) }

    private companion object {
        val SAFE_SEGMENT = Regex("[A-Za-z0-9_-]{1,255}")
    }
}
