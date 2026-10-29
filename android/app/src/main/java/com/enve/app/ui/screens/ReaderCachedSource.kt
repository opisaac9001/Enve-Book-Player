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
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(32768)
            var count = input.read(buffer)
            while (count >= 0) {
                digest.update(buffer, 0, count)
                count = input.read(buffer)
            }
        }
        digest.digest().joinToString("") { "%02x".format(it) }.equals(sha256, ignoreCase = true)
    } catch (_: java.io.IOException) { false }

    fun providerFileId(file: File, bookId: String, format: EbookSourceFormat): String? {
        val name = bookId.replace(Regex("[^a-zA-Z0-9_-]"), "_")
        if (!file.name.startsWith("$name.") || !file.name.endsWith(".${format.extension}")) return null
        return file.name.removePrefix("$name.").removeSuffix(".${format.extension}")
            .takeIf { file.name != "$name.${format.extension}" && it != "readaloud" }
    }

    fun find(directory: File, bookId: String, format: EbookSourceFormat, providerFileId: String? = null): File? {
        val name = bookId.replace(Regex("[^a-zA-Z0-9_-]"), "_")
        val discriminator = providerFileId?.replace(Regex("[^a-zA-Z0-9_-]"), "_")?.takeIf { it.isNotBlank() }
        val exact = if (format == EbookSourceFormat.READALOUD) "$name.readaloud.${format.extension}"
            else discriminator?.let { "$name.$it.${format.extension}" }
        val candidates = if (exact != null) listOf(File(directory, exact)) else {
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
