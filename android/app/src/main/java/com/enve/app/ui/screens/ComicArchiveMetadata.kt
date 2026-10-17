package com.enve.app.ui.screens

import android.os.ParcelFileDescriptor
import com.enve.app.viewmodel.ComicReadingDirection
import java.io.File
import java.io.InputStream
import java.io.StringReader
import java.util.zip.ZipFile
import javax.xml.parsers.SAXParserFactory
import me.zhanghai.android.libarchive.Archive
import me.zhanghai.android.libarchive.ArchiveEntry
import me.zhanghai.android.libarchive.ArchiveException
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler

internal fun readComicArchiveDirection(archive: File): ComicReadingDirection? = try {
    if (archive.looksLikeZipPackage()) {
        ZipFile(archive).use { zip ->
            val entry = zip.entries().asSequence().firstOrNull {
                !it.isDirectory && it.name.substringAfterLast('/').equals("ComicInfo.xml", ignoreCase = true)
            }
            entry?.let { zip.getInputStream(it).use(::parseComicInfoReadingDirection) }
        }
    } else {
        var handle = 0L
        val temporary = File.createTempFile("comic-metadata-", ".xml", archive.parentFile)
        try {
            handle = Archive.readNew()
            Archive.readSupportFilterAll(handle)
            Archive.readSupportFormatAll(handle)
            Archive.readOpenFileName(handle, archive.absolutePath.toByteArray(), 16_384)
            var direction: ComicReadingDirection? = null
            while (true) {
                val entry = try {
                    Archive.readNextHeader(handle)
                } catch (e: ArchiveException) {
                    if (e.code == Archive.ERRNO_EOF) break else throw e
                }
                if (entry == 0L) break
                val name = ArchiveEntry.pathnameUtf8(entry).orEmpty()
                if (!name.substringAfterLast('/').equals("ComicInfo.xml", ignoreCase = true)) continue
                ParcelFileDescriptor.open(temporary, ParcelFileDescriptor.MODE_READ_WRITE or ParcelFileDescriptor.MODE_TRUNCATE).use {
                    Archive.readDataIntoFd(handle, it.fd)
                }
                direction = temporary.inputStream().use(::parseComicInfoReadingDirection)
                break
            }
            direction
        } finally {
            if (handle != 0L) Archive.readFree(handle)
            temporary.delete()
        }
    }
} catch (_: Exception) {
    null
}

internal fun parseComicInfoReadingDirection(input: InputStream): ComicReadingDirection? {
    var inManga = false
    val value = StringBuilder()
    val handler = object : DefaultHandler() {
        override fun resolveEntity(publicId: String?, systemId: String?) = InputSource(StringReader(""))

        override fun startElement(uri: String?, localName: String?, qName: String?, attributes: org.xml.sax.Attributes?) {
            if (localName.equals("Manga", ignoreCase = true)) inManga = true
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            if (inManga) value.append(ch, start, length)
        }

        override fun endElement(uri: String?, localName: String?, qName: String?) {
            if (localName.equals("Manga", ignoreCase = true)) inManga = false
        }
    }
    SAXParserFactory.newInstance().apply { isNamespaceAware = true }.newSAXParser().parse(input, handler)
    return when (value.toString().trim().lowercase()) {
        "yesandrighttoleft" -> ComicReadingDirection.RIGHT_TO_LEFT
        "yes", "no" -> ComicReadingDirection.LEFT_TO_RIGHT
        else -> null
    }
}
