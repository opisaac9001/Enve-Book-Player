package com.enve.app.webimport

import okhttp3.HttpUrl
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

internal class WebStoryEpubWriter(file: File, private val maxBytes: Long) : Closeable {

    private class Chapter(val href: String, val title: String)

    private val zip = ZipOutputStream(BufferedOutputStream(FileOutputStream(file)))
    private val chapters = mutableListOf<Chapter>()
    private var bytesWritten = 0L

    val chapterCount: Int get() = chapters.size

    init {
        val mimetype = "application/epub+zip".toByteArray(Charsets.US_ASCII)
        val entry = ZipEntry("mimetype").apply {
            method = ZipEntry.STORED
            size = mimetype.size.toLong()
            compressedSize = mimetype.size.toLong()
            crc = CRC32().apply { update(mimetype) }.value
        }
        zip.putNextEntry(entry)
        zip.write(mimetype)
        zip.closeEntry()
    }

    fun addChapter(title: String, bodyXhtml: String, language: String, source: HttpUrl) {
        val chapter = Chapter("chapter-%04d.xhtml".format(java.util.Locale.ROOT, chapters.size + 1), title)
        write(chapter.href, chapterDocument(title, bodyXhtml, language, source).toByteArray(Charsets.UTF_8))
        chapters += chapter
    }

    fun finish(metadata: WebStoryMetadata, modified: Instant) {
        write("style.css", STYLESHEET.toByteArray(Charsets.UTF_8))
        write("nav.xhtml", navDocument(metadata.language).toByteArray(Charsets.UTF_8))
        write("content.opf", packageDocument(metadata, modified).toByteArray(Charsets.UTF_8))
        write(CONTAINER_PATH, CONTAINER.toByteArray(Charsets.UTF_8), directory = null)
    }

    override fun close() = zip.close()

    private fun write(href: String, bytes: ByteArray, directory: String? = CONTENT_DIR) {
        if (bytesWritten + bytes.size > maxBytes) {
            throw WebStoryImportException(WebStoryImportException.Reason.STORY_TOO_LARGE)
        }
        zip.putNextEntry(ZipEntry(directory?.let { "$it/$href" } ?: href))
        zip.write(bytes)
        zip.closeEntry()
        bytesWritten += bytes.size
    }

    private fun chapterDocument(title: String, body: String, language: String, source: HttpUrl) = buildString {
        append(xhtmlHead(title, language))
        append("<body><section epub:type=\"chapter\" role=\"doc-chapter\"><h1>")
        append(escape(title))
        append("</h1>")
        append(body)
        append("<p class=\"source\"><a href=\"").append(escape(source.toString())).append("\">Original page</a></p>")
        append("</section></body></html>")
    }

    private fun navDocument(language: String) = buildString {
        append(xhtmlHead("Contents", language))
        append("<body><nav epub:type=\"toc\" id=\"toc\" role=\"doc-toc\"><h1>Contents</h1><ol>")
        for (chapter in chapters) {
            append("<li><a href=\"").append(chapter.href).append("\">").append(escape(chapter.title)).append("</a></li>")
        }
        append("</ol></nav></body></html>")
    }

    private fun packageDocument(metadata: WebStoryMetadata, modified: Instant) = buildString {
        val language = escape(metadata.language)
        append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        append("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\" xml:lang=\"$language\">")
        append("<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">")
        append("<dc:identifier id=\"book-id\">urn:uuid:").append(UUID.randomUUID()).append("</dc:identifier>")
        append("<dc:title>").append(escape(metadata.title)).append("</dc:title>")
        metadata.author?.let { append("<dc:creator id=\"creator\">").append(escape(it)).append("</dc:creator>") }
        append("<dc:language>").append(language).append("</dc:language>")
        metadata.description?.let { append("<dc:description>").append(escape(it)).append("</dc:description>") }
        append("<dc:publisher>").append(escape(metadata.sourceUrl.host)).append("</dc:publisher>")
        append("<dc:source>").append(escape(metadata.sourceUrl.toString())).append("</dc:source>")
        append("<meta property=\"dcterms:modified\">")
        append(DateTimeFormatter.ISO_INSTANT.format(modified.truncatedTo(ChronoUnit.SECONDS)))
        append("</meta></metadata><manifest>")
        append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"$XHTML\" properties=\"nav\"/>")
        append("<item id=\"style\" href=\"style.css\" media-type=\"text/css\"/>")
        chapters.forEachIndexed { index, chapter ->
            append("<item id=\"chapter-").append(index + 1).append("\" href=\"").append(chapter.href)
            append("\" media-type=\"$XHTML\"/>")
        }
        append("</manifest><spine>")
        chapters.indices.forEach { append("<itemref idref=\"chapter-").append(it + 1).append("\"/>") }
        append("</spine></package>")
    }

    private fun xhtmlHead(title: String, language: String) = buildString {
        val lang = escape(language)
        append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n")
        append("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"$lang\" xml:lang=\"$lang\">")
        append("<head><meta charset=\"UTF-8\"/><title>").append(escape(title)).append("</title>")
        append("<link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/></head>")
    }

    companion object {
        private const val CONTENT_DIR = "OEBPS"
        private const val CONTAINER_PATH = "META-INF/container.xml"
        private const val XHTML = "application/xhtml+xml"

        private const val CONTAINER = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
            "<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">" +
            "<rootfiles><rootfile full-path=\"$CONTENT_DIR/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles>" +
            "</container>"

        private const val STYLESHEET = "body { margin: 0 5%; line-height: 1.5; }\n" +
            "h1 { font-size: 1.4em; margin: 1.2em 0 1em; }\n" +
            "p { margin: 0 0 0.8em; }\n" +
            "p.source { margin-top: 2em; font-size: 0.85em; }\n" +
            "blockquote { margin: 1em 1.5em; }\n" +
            "pre { white-space: pre-wrap; }\n" +
            "table { border-collapse: collapse; }\n" +
            "th, td { border: 1px solid currentColor; padding: 0.2em 0.4em; }\n"

        fun escape(text: String): String = buildString(text.length) {
            for (char in WebStorySanitizer.xmlSafe(text)) {
                when (char) {
                    '&' -> append("&amp;")
                    '<' -> append("&lt;")
                    '>' -> append("&gt;")
                    '"' -> append("&quot;")
                    '\'' -> append("&apos;")
                    else -> append(char)
                }
            }
        }
    }
}
