package com.enve.app.data.export

import android.content.ClipData
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

sealed interface AnnotationFileFormat {
    val label: String
    val mimeType: String
    val extension: String

    data class Text(val format: AnnotationExporter.Format) : AnnotationFileFormat {
        override val label: String get() = when (format) {
            AnnotationExporter.Format.MARKDOWN -> "Markdown"
            AnnotationExporter.Format.JSON -> "JSON"
            AnnotationExporter.Format.PLAIN_TEXT -> "Plain text"
            AnnotationExporter.Format.CSV -> "CSV"
            AnnotationExporter.Format.HTML -> "HTML"
            AnnotationExporter.Format.W3C_ANNOTATIONS -> "W3C annotations"
        }
        override val mimeType: String get() = AnnotationExporter.mimeType(format)
        override val extension: String get() = AnnotationExporter.extension(format)
    }

    data object Pdf : AnnotationFileFormat {
        override val label = "PDF"
        override val mimeType = "application/pdf"
        override val extension = "pdf"
    }

    companion object {
        val all: List<AnnotationFileFormat> = AnnotationExporter.Format.entries.map(::Text) + Pdf
    }
}

object AnnotationShareFiles {
    private const val DIRECTORY = "annotation-exports"
    private const val KEPT_EXPORTS = 10

    suspend fun share(
        context: Context,
        books: List<AnnotationExportBook>,
        format: AnnotationFileFormat,
        name: String,
    ) {
        val application = context.applicationContext
        val file = withContext(Dispatchers.IO) { write(application, books, format, name) }
        val uri = FileProvider.getUriForFile(application, "${application.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = format.mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, name)
            clipData = ClipData.newRawUri(name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, "Share $name"))
    }

    private fun write(context: Context, books: List<AnnotationExportBook>, format: AnnotationFileFormat, name: String): File {
        val root = File(context.cacheDir, DIRECTORY).apply { mkdirs() }
        root.listFiles()?.sortedByDescending { it.lastModified() }?.drop(KEPT_EXPORTS - 1)?.forEach { it.deleteRecursively() }
        val directory = File(root, UUID.randomUUID().toString()).apply { mkdirs() }
        val file = File(directory, "${fileName(name)}.${format.extension}")
        when (format) {
            is AnnotationFileFormat.Text -> file.writeText(AnnotationExporter.export(books, format.format), Charsets.UTF_8)
            AnnotationFileFormat.Pdf -> file.outputStream().use { AnnotationPdfRenderer.render(books, it) }
        }
        return file
    }

    internal fun fileName(name: String): String =
        name.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim(' ', '.')
            .take(80)
            .trim()
            .ifEmpty { "Enve highlights" }
}
