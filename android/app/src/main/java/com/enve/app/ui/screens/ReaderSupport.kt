package com.enve.app.ui.screens

import com.enve.core.data.local.PreferencesManager
import android.os.ParcelFileDescriptor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import me.zhanghai.android.libarchive.Archive
import me.zhanghai.android.libarchive.ArchiveEntry
import me.zhanghai.android.libarchive.ArchiveException
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import kotlin.math.roundToInt
import java.util.Locale
import java.util.Properties
import java.util.zip.ZipFile

enum class ReaderFormat(val serverType: String) {
    EPUB("EPUB"),
    PDF("PDF"),
    CBZ("CBZ"),
    CBX("CBX"),
    CBR("CBR"),
    UNKNOWN("UNKNOWN");

    val cacheExtension: String
        get() = serverType.lowercase(Locale.US)

    val displayName: String
        get() = when (this) {
            EPUB -> "EPUB"
            PDF -> "PDF"
            CBZ -> "CBZ"
            CBX -> "CBX"
            CBR -> "CBR"
            UNKNOWN -> "book"
        }

    val isComic: Boolean
        get() = this == CBZ || this == CBX || this == CBR

    companion object {
        fun fromServerType(value: String?): ReaderFormat = when (value?.uppercase(Locale.US)) {
            "EPUB" -> EPUB
            "PDF" -> PDF
            "CBZ" -> CBZ
            "CBX" -> CBX
            "CBR" -> CBR
            else -> UNKNOWN
        }
    }
}

internal suspend fun downloadReaderFile(
    cacheDir: File,
    okHttpClient: OkHttpClient,
    bookId: String,
    format: ReaderFormat,
    downloadUrl: String,
    contentResolver: android.content.ContentResolver? = null,
    onStatus: suspend (String) -> Unit = {},
    onProgress: suspend (Int?) -> Unit = {},
): File {
    val dir = File(cacheDir, "reader-files").also { it.mkdirs() }
    val safeName = bookId.replace(Regex("[^a-zA-Z0-9_-]"), "_")
    val cached = File(dir, "$safeName.${format.cacheExtension}")

    if (cached.exists() && cached.length() > 10_240) {
        onStatus("Loading cached ${format.displayName}…")
        return cached
    }

    onStatus("Downloading…")
    onProgress(0)

    if (contentResolver != null && (downloadUrl.startsWith("content://") || downloadUrl.startsWith("file://"))) {
        return withContext(Dispatchers.IO) {
            val tmp = File(dir, "$safeName.tmp")
            val input = contentResolver.openInputStream(android.net.Uri.parse(downloadUrl))
                ?: throw IllegalStateException("Couldn't open the local file. Was it moved or deleted?")
            input.use { inp -> FileOutputStream(tmp).use { out -> inp.copyTo(out) } }
            if (tmp.length() < 1024) {
                tmp.delete()
                throw IllegalStateException("File too small")
            }
            if (cached.exists()) cached.delete()
            if (!tmp.renameTo(cached)) {
                tmp.copyTo(cached, overwrite = true)
                tmp.delete()
            }
            cached
        }
    }

    return withContext(Dispatchers.IO) {
        val resp = okHttpClient.newCall(Request.Builder().url(downloadUrl).build()).execute()
        if (!resp.isSuccessful) throw IllegalStateException("HTTP ${resp.code}")
        val body = resp.body ?: throw IllegalStateException("Empty body")
        val len = body.contentLength()
        val tmp = File(dir, "$safeName.tmp")

        FileOutputStream(tmp).use { out ->
            body.byteStream().use { inp ->
                val buf = ByteArray(16_384)
                var total = 0L
                var count: Int
                while (inp.read(buf).also { count = it } != -1) {
                    out.write(buf, 0, count)
                    total += count
                    if (len > 0) {
                        val pct = (total * 100 / len).toInt()
                        onProgress(pct)
                    }
                }
            }
        }

        if (tmp.length() < 1024) {
            tmp.delete()
            throw IllegalStateException("File too small")
        }

        if (cached.exists()) cached.delete()
        if (!tmp.renameTo(cached)) {
            tmp.copyTo(cached, overwrite = true)
            tmp.delete()
        }
        cached
    }
}

internal fun File.looksLikeZipPackage(): Boolean {
    if (!exists() || length() < 4) return false
    return runCatching {
        BufferedInputStream(inputStream()).use { input ->
            val signature = ByteArray(4)
            val count = input.read(signature)
            count == 4 && signature[0] == 'P'.code.toByte() && signature[1] == 'K'.code.toByte()
        }
    }.getOrDefault(false)
}

internal fun File.looksLikePdfFile(): Boolean {
    if (!exists() || length() < 4) return false
    return runCatching {
        BufferedInputStream(inputStream()).use { input ->
            val signature = ByteArray(4)
            val count = input.read(signature)
            count == 4 && signature[0] == '%'.code.toByte() && signature[1] == 'P'.code.toByte() && signature[2] == 'D'.code.toByte() && signature[3] == 'F'.code.toByte()
        }
    }.getOrDefault(false)
}

internal fun parseSavedPage(locator: String?, format: ReaderFormat): Int {
    if (locator.isNullOrBlank()) return 0
    val jsonPage = Regex("""\"page\"\s*:\s*(\d+)""").find(locator)?.groupValues?.getOrNull(1)?.toIntOrNull()
    return when (format) {
        ReaderFormat.PDF -> (jsonPage ?: 1) - 1
        ReaderFormat.CBZ, ReaderFormat.CBX, ReaderFormat.CBR -> {
            val pageNumber = jsonPage
                ?: locator.substringAfter(':', "").toIntOrNull()
                ?: locator.trim().toIntOrNull()
                ?: 1
            pageNumber - 1
        }
        else -> 0
    }.coerceAtLeast(0)
}

internal fun pageIndexFromProgress(progress: Float?, pageCount: Int): Int {
    val pages = pageCount.coerceAtLeast(1)
    val fraction = progress?.takeIf { it.isFinite() }?.coerceIn(0f, 1f) ?: return 0
    if (fraction <= 0f) return 0
    return (fraction * pages.toFloat())
        .roundToInt()
        .coerceIn(1, pages) - 1
}

internal fun buildPageLocator(format: ReaderFormat, pageIndex: Int): String? {
    val pageNumber = pageIndex.coerceAtLeast(0) + 1
    return when (format) {
        ReaderFormat.PDF -> "{\"page\":$pageNumber}"
        ReaderFormat.CBZ -> "cbz-page:$pageNumber"
        ReaderFormat.CBX -> "cbx-page:$pageNumber"
        ReaderFormat.CBR -> "cbr-page:$pageNumber"
        else -> null
    }
}

internal suspend fun loadOrExtractComicPages(
    cacheDir: File,
    archive: File,
    format: ReaderFormat = ReaderFormat.CBZ,
    onStatus: suspend (String) -> Unit = {},
): List<File> = withContext(Dispatchers.IO) {
    val archiveKey = archive.nameWithoutExtension.replace(Regex("[^a-zA-Z0-9._-]"), "_")
    val extractDir = File(cacheDir, "comic-pages/$archiveKey").also { it.mkdirs() }
    val manifest = File(extractDir, "manifest.properties")

    loadComicManifest(manifest, archive, extractDir)?.let { cachedPages ->
        onStatus("Loading cached pages...")
        return@withContext cachedPages
    }

    clearExtractedComicPages(extractDir, manifest)

    val pages = when {
        archive.looksLikeZipPackage() -> {
            onStatus("Indexing comic pages...")
            extractZipComicPages(archive, extractDir)
        }
        format == ReaderFormat.CBR || format == ReaderFormat.CBX -> {
            onStatus("Extracting CBR pages...")
            extractArchiveComicPages(archive, extractDir)
        }
        else -> throw IllegalStateException("Unsupported ${format.displayName} archive signature")
    }

    saveComicManifest(manifest, archive, extractDir, pages)
    pages
}

private fun extractZipComicPages(archive: File, extractDir: File): List<File> {
    return ZipFile(archive).use { zip ->
        zip.entries().toList()
            .filter { !it.isDirectory }
            .filter { entry -> entry.name.isSupportedComicPageName() }
            .sortedBy { it.name.normalizedComicSortKey() }
            .mapIndexed { index, entry ->
                val outFile = normalizedComicPageFile(extractDir, index, entry.name)
                zip.getInputStream(entry).use { input ->
                    outFile.outputStream().use { output -> input.copyTo(output) }
                }
                outFile
            }
    }
}

private fun extractArchiveComicPages(archive: File, extractDir: File): List<File> {
    val rawDir = File(extractDir, "raw-archive-pages").also {
        if (it.exists()) it.deleteRecursively()
        it.mkdirs()
    }
    val extracted = mutableListOf<Pair<String, File>>()

    var archiveHandle = 0L
    try {
        archiveHandle = Archive.readNew()
        Archive.readSupportFilterAll(archiveHandle)
        Archive.readSupportFormatAll(archiveHandle)
        Archive.readOpenFileName(archiveHandle, archive.absolutePath.toByteArray(), 16_384)

        while (true) {
            val entry = try {
                Archive.readNextHeader(archiveHandle)
            } catch (e: ArchiveException) {
                if (e.code == Archive.ERRNO_EOF) break else throw e
            }
            if (entry == 0L) break

            val entryName = ArchiveEntry.pathnameUtf8(entry).orEmpty()
            if (!entryName.isSupportedComicPageName()) continue

            val rawFile = File(rawDir, extracted.size.toString().padStart(5, '0') + "-" + entryName.safeArchiveLeafName())
            var descriptor: ParcelFileDescriptor? = null
            try {
                descriptor = ParcelFileDescriptor.open(
                    rawFile,
                    ParcelFileDescriptor.MODE_READ_WRITE or
                        ParcelFileDescriptor.MODE_CREATE or
                        ParcelFileDescriptor.MODE_TRUNCATE,
                )
                Archive.readDataIntoFd(archiveHandle, descriptor.fd)
            } finally {
                descriptor?.close()
            }
            if (rawFile.length() > 0L) {
                extracted += entryName to rawFile
            } else {
                rawFile.delete()
            }
        }
    } finally {
        if (archiveHandle != 0L) Archive.readFree(archiveHandle)
    }

    return try {
        extracted
            .sortedBy { (entryName, _) -> entryName.normalizedComicSortKey() }
            .mapIndexed { index, (entryName, rawFile) ->
                val outFile = normalizedComicPageFile(extractDir, index, entryName)
                rawFile.copyTo(outFile, overwrite = true)
                outFile
            }
    } finally {
        rawDir.deleteRecursively()
    }
}

private fun String.isSupportedComicPageName(): Boolean {
    val name = lowercase(Locale.US)
    return name.endsWith(".jpg") ||
        name.endsWith(".jpeg") ||
        name.endsWith(".png") ||
        name.endsWith(".webp")
}

private fun String.normalizedComicSortKey(): String =
    replace('\\', '/')
        .split('/')
        .joinToString("/") { segment -> segment.lowercase(Locale.US).padNumericRuns() }

private fun String.padNumericRuns(): String = replace(Regex("\\d+")) { match ->
    match.value.padStart(12, '0')
}

private fun String.safeArchiveLeafName(): String =
    replace('\\', '/')
        .substringAfterLast('/')
        .replace(Regex("[^a-zA-Z0-9._-]"), "_")
        .ifBlank { "page" }

private fun normalizedComicPageFile(extractDir: File, index: Int, sourceName: String): File {
    val extension = sourceName.substringAfterLast('.', "jpg")
        .lowercase(Locale.US)
        .replace(Regex("[^a-z0-9]"), "")
        .ifBlank { "jpg" }
    return File(extractDir, index.toString().padStart(4, '0') + "." + extension)
}

private fun clearExtractedComicPages(extractDir: File, manifest: File) {
    extractDir.listFiles()?.forEach { file ->
        if (file != manifest) file.deleteRecursively()
    }
}

private fun loadComicManifest(manifest: File, archive: File, extractDir: File): List<File>? = runCatching {
    if (!manifest.exists() || manifest.length() == 0L) return@runCatching null
    val props = Properties().apply { manifest.inputStream().use { load(it) } }
    val length = props.getProperty("archiveLength")?.toLongOrNull()
    val modified = props.getProperty("archiveLastModified")?.toLongOrNull()
    val pageCount = props.getProperty("pageCount")?.toIntOrNull() ?: 0
    if (length != archive.length() || modified != archive.lastModified() || pageCount <= 0) {
        return@runCatching null
    }

    val pages = (0 until pageCount).mapNotNull { index ->
        props.getProperty("page.$index")?.let { relativeName -> File(extractDir, relativeName) }
    }
    if (pages.size != pageCount || pages.any { !it.exists() || it.length() == 0L }) {
        return@runCatching null
    }
    pages
}.getOrNull()

private fun saveComicManifest(manifest: File, archive: File, extractDir: File, pages: List<File>) {
    runCatching {
        val props = Properties().apply {
            setProperty("archiveLength", archive.length().toString())
            setProperty("archiveLastModified", archive.lastModified().toString())
            setProperty("pageCount", pages.size.toString())
            pages.forEachIndexed { index, file ->
                setProperty("page.$index", file.relativeTo(extractDir).path.replace('\\', '/'))
            }
        }
        manifest.outputStream().use { props.store(it, "Enve comic page manifest") }
    }
}
