package com.enve.app.ui.screens

import com.enve.app.document.EbookSourceFormat
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.Locale
import java.util.zip.ZipFile

internal inline fun File.writePublication(format: EbookSourceFormat, write: (OutputStream) -> Unit): File {
    val pending = File.createTempFile("enve-book-", ".tmp", parentFile)
    try {
        pending.outputStream().use(write)
        if (pending.length() == 0L) throw IOException("File is empty")
        validateDownloadedEbookSource(pending, format)
        Files.move(pending.toPath(), toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        return this
    } finally {
        pending.delete()
    }
}

internal fun validateDownloadedEbookSource(file: File, format: EbookSourceFormat) {
    if (!isZipBackedEbook(format) || looksLikeZip(file)) return
    file.delete()
    throw Exception("The server did not return a valid ${format.displayName} file.")
}

internal fun isZipBackedEbook(format: EbookSourceFormat): Boolean =
    format.isEpubPackage || format == EbookSourceFormat.READALOUD

internal fun looksLikeZip(file: File): Boolean {
    if (!file.exists() || file.length() < ZIP_END_RECORD_BYTES) return false
    return runCatching {
        RandomAccessFile(file, "r").use { archive ->
            val header = ByteArray(2)
            archive.readFully(header)
            if (header[0] != 'P'.code.toByte() || header[1] != 'K'.code.toByte()) return@use false
            val tailLength = minOf(archive.length(), MAX_ZIP_END_RECORD_SEARCH_BYTES).toInt()
            val tail = ByteArray(tailLength)
            archive.seek(archive.length() - tailLength)
            archive.readFully(tail)
            (tail.size - 4 downTo 0).any { index ->
                tail[index] == 'P'.code.toByte() && tail[index + 1] == 'K'.code.toByte() &&
                    tail[index + 2] == 0x05.toByte() && tail[index + 3] == 0x06.toByte()
            }
        }
    }.getOrDefault(false)
}

internal fun File.sha256(): String {
    val digest = MessageDigest.getInstance("SHA-256")
    inputStream().buffered().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
}

internal fun isReflowableEpub(file: File): Boolean = runCatching {
    ZipFile(file).use { zip ->
        val opfEntry = zip.entries().asSequence()
            .filterNot { it.isDirectory }
            .filter { it.name.endsWith(".opf", ignoreCase = true) }
            .minByOrNull { it.name.length }
            ?: return@use false
        val packageDocument = zip.getInputStream(opfEntry)
            .bufferedReader()
            .use { it.readText() }
            .lowercase(Locale.ROOT)
        val fixedLayoutMarkers = listOf(
            "pre-paginated",
            "fixed-layout",
            "rendition:layout-pre-paginated",
            "original-resolution",
        )
        fixedLayoutMarkers.none(packageDocument::contains)
    }
}.getOrDefault(false)

private const val ZIP_END_RECORD_BYTES = 22L
private const val MAX_ZIP_END_RECORD_SEARCH_BYTES = 65_557L
