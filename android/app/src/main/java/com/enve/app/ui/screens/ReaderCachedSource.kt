package com.enve.app.ui.screens

import com.enve.app.document.EbookSourceFormat
import java.io.File
import java.security.MessageDigest
import com.enve.core.data.model.BookSource

internal object ReaderCachedSource {
    fun directory(cache: File, source: BookSource, connectionId: String?): File {
        val root = File(cache, "ebooks")
        if (source == BookSource.LOCAL) return root
        val identity = "${source.name}|${connectionId.orEmpty()}"
        val digest = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return File(root, digest)
    }

    fun matches(file: File, sha256: String): Boolean = try {
        file.sha256().equals(sha256, ignoreCase = true)
    } catch (_: java.io.IOException) { false }

    private fun safePart(value: String) = value.replace(Regex("[^a-zA-Z0-9_-]"), "_")

    fun filename(bookId: String, format: EbookSourceFormat, providerFileId: String?): String {
        val suffix = if (format == EbookSourceFormat.READALOUD) "readaloud" else providerFileId?.let(::safePart)
        return listOfNotNull(safePart(bookId), suffix?.takeIf { it.isNotBlank() }, format.extension).joinToString(".")
    }

    fun providerFileId(file: File, bookId: String, format: EbookSourceFormat): String? {
        val name = safePart(bookId)
        if (!file.name.startsWith("$name.") || !file.name.endsWith(".${format.extension}")) return null
        return file.name.removePrefix("$name.").removeSuffix(".${format.extension}")
            .takeIf { file.name != "$name.${format.extension}" && it != "readaloud" }
    }

    fun find(directory: File, bookId: String, format: EbookSourceFormat, providerFileId: String? = null): File? {
        val name = safePart(bookId)
        val candidates = if (format == EbookSourceFormat.READALOUD || !providerFileId.isNullOrEmpty()) {
            listOf(File(directory, filename(bookId, format, providerFileId)))
        } else {
            val pattern = Regex("^${Regex.escape(name)}(?:\\.[a-zA-Z0-9_-]+)?\\.${Regex.escape(format.extension)}$")
            directory.listFiles().orEmpty().filter { pattern.matches(it.name) && !it.name.contains(".readaloud.") }
        }
        return candidates.filter { usable(it, format) }.singleOrNull()
    }

    private fun usable(file: File, format: EbookSourceFormat): Boolean {
        if (!file.isFile || file.length() == 0L) return false
        if (!format.isEpubPackage && format != EbookSourceFormat.READALOUD) return true
        return try {
            file.inputStream().use { it.read() == 0x50 && it.read() == 0x4b && it.read() == 0x03 && it.read() == 0x04 }
        } catch (_: java.io.IOException) { false }
    }
}
