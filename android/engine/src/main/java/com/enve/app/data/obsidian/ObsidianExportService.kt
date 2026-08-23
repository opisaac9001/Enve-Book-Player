package com.enve.app.data.obsidian

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import com.enve.app.data.repository.AnnotationRepository
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext

data class ObsidianExportResult(
    val bookCount: Int,
    val annotationCount: Int,
)

@Singleton
class ObsidianExportService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val annotationRepository: AnnotationRepository,
    private val bookCacheDao: BookCacheDao,
) {
    suspend fun exportAll(treeUriString: String): ObsidianExportResult = withContext(Dispatchers.IO) {
        val treeUri = Uri.parse(treeUriString)
        val root = DocumentFile.fromTreeUri(context, treeUri)
            ?: error("Selected vault folder is no longer available")
        if (!root.canWrite()) error("Selected vault folder is read-only")

        val enveFolder = root.findFile(EXPORT_FOLDER)?.takeIf { it.isDirectory }
            ?: root.createDirectory(EXPORT_FOLDER)
            ?: error("Could not create $EXPORT_FOLDER folder")

        val annotations = annotationRepository.all().first()
            .filter { it.deletedAt == null }
        val grouped = annotations.groupBy { it.bookId }
        val usedNames = HashSet<String>()

        grouped.forEach { (bookId, rows) ->
            val book = bookCacheDao.getById(bookId)?.toBook()
                ?: com.enve.core.data.model.Book(
                    id = bookId,
                    title = bookId,
                    source = com.enve.core.data.model.BookSource.LOCAL,
                    mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
                )
            val baseName = uniqueName(
                ObsidianMarkdownRenderer.filenameFor(book, bookId).removeSuffix(".md"),
                bookId,
                usedNames,
            )
            val fileName = "$baseName.md"
            val rendered = ObsidianMarkdownRenderer.renderBook(book, bookId, rows)
            val file = enveFolder.findFile(fileName)?.takeIf { it.isFile }
                ?: enveFolder.createFile("text/markdown", fileName)
                ?: error("Could not create $fileName")
            val existing = context.contentResolver.openInputStream(file.uri)
                ?.bufferedReader(Charsets.UTF_8)
                ?.use { it.readText() }
                .orEmpty()
            val markdown = ObsidianMarkdownRenderer.merge(existing, rendered, ObsidianUpdatePolicy.MAGIC)
            context.contentResolver.openOutputStream(file.uri, "wt")?.use { stream ->
                stream.write(markdown.toByteArray(Charsets.UTF_8))
            } ?: error("Could not write $fileName")
        }

        ObsidianExportResult(bookCount = grouped.size, annotationCount = annotations.size)
    }

    private fun uniqueName(base: String, bookId: String, usedNames: MutableSet<String>): String {
        if (usedNames.add(base)) return base
        val suffix = safeFileName(bookId).takeLast(8).ifBlank { Integer.toHexString(bookId.hashCode()) }
        val withSuffix = "$base-$suffix"
        return if (usedNames.add(withSuffix)) withSuffix else "$withSuffix-${usedNames.size}"
    }

    private fun safeFileName(raw: String): String =
        raw.trim()
            .replace(Regex("[\\\\/:*?\"<>|]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim('.', ' ')

    private companion object {
        const val EXPORT_FOLDER = "Enve"
    }
}
