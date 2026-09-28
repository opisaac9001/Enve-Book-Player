package com.enve.app.data.sync

import com.enve.core.data.model.Book
import java.net.URLDecoder

object KOReaderDocumentId {

    private val EBOOK_EXTENSIONS =
        setOf("epub", "pdf", "cbz", "cbr", "mobi", "azw3", "fb2", "txt", "djvu")

    fun fromFilename(pathOrName: String): String? =
        basename(pathOrName)?.let { md5Hash(it) }

    fun filenameSuggestion(book: Book): String? = basename(book.id)
        ?.takeIf { it.substringAfterLast('.', "").lowercase() in EBOOK_EXTENSIONS }

    private fun basename(pathOrName: String): String? = percentDecode(pathOrName.trim())
        .trimEnd('/', '\\')
        .substringAfterLast('/')
        .substringAfterLast('\\')
        .trim()
        .takeIf { it.isNotEmpty() }

    private fun percentDecode(value: String): String {
        if (!value.contains('%')) return value
        return runCatching { URLDecoder.decode(value.replace("+", "%2B"), "UTF-8") }
            .getOrDefault(value)
    }
}
