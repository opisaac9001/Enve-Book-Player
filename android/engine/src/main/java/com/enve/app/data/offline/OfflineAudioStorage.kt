package com.enve.app.data.offline

import android.content.Context
import com.enve.core.data.model.Book
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OfflineAudioStorage @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
    }

    private val rootDir = File(context.filesDir, "offline-audio").also { it.mkdirs() }

    private val pendingDir = File(rootDir, ".pending").also { it.mkdirs() }

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
                it.length() > 0L
        }
    }

    fun coverFile(bookId: String): File =
        File(bookDirectory(bookId).also { it.mkdirs() }, "cover.img")

    fun relativePath(file: File): String =
        file.relativeTo(rootDir).invariantSeparatorsPath

    fun absolutePath(relativePath: String): File =
        File(rootDir, relativePath)

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
        val dirs = rootDir.listFiles()?.filter { it.isDirectory }.orEmpty()
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
        bookDirectory(bookId).deleteRecursively()
    }
}
