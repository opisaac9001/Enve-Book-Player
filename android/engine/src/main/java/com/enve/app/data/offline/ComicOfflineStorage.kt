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
class ComicOfflineStorage @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val rootDir = File(context.filesDir, "offline-comics").also { it.mkdirs() }

    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }

    private fun safeId(bookId: String): String = bookId.replace(Regex("[^a-zA-Z0-9_-]"), "_")

    private fun bookDirectory(bookId: String): File = File(rootDir, safeId(bookId))

    fun isDownloaded(bookId: String): Boolean {
        val dir = bookDirectory(bookId)
        if (!dir.exists()) return false
        return dir.listFiles().orEmpty().any {
            it.name.startsWith("book.") && it.length() > 1024 && it.name != "book.json"
        }
    }

    fun getDownloadedFile(bookId: String): File? {
        val dir = bookDirectory(bookId)
        if (!dir.exists()) return null
        return dir.listFiles().orEmpty()
            .firstOrNull { it.name.startsWith("book.") && it.length() > 1024 && it.name != "book.json" }
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
        if (final.exists()) final.delete()
        if (!temp.renameTo(final)) {
            temp.copyTo(final, overwrite = true)
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
            .filter { it.isDirectory && isDownloadedDir(it) }
            .mapNotNull { dir ->
                val file = File(dir, "book.json")
                if (!file.exists()) null
                else runCatching { json.decodeFromString<Book>(file.readText()) }.getOrNull()
            }

    fun removeDownload(bookId: String) {
        bookDirectory(bookId).deleteRecursively()
    }

    fun listDownloadedBookIds(): Set<String> {
        return rootDir.listFiles().orEmpty()
            .filter { it.isDirectory && isDownloadedDir(it) }
            .mapNotNull { dir ->

                getManifest(dir.name)?.id ?: dir.name
            }
            .toSet()
    }

    private fun isDownloadedDir(dir: File): Boolean =
        dir.listFiles().orEmpty().any {
            it.name.startsWith("book.") && it.length() > 1024 && it.name != "book.json"
        }
}
