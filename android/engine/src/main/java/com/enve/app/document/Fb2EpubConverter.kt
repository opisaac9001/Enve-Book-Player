package com.enve.app.document

import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode
import org.jsoup.parser.Parser
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.Base64
import java.util.Locale
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

internal class Fb2EpubConverter {
    private data class Metadata(
        val title: String,
        val author: String,
        val publisher: String?,
        val language: String,
        val coverId: String?,
    )

    private data class Resource(
        val sourceId: String,
        val href: String,
        val mediaType: String,
        val data: ByteArray,
    )

    private data class Chapter(
        val title: String,
        val href: String,
        val content: String,
    )

    fun convertToEpub(source: File, destination: File): File {
        val document = try {
            Jsoup.parse(source, null, "", Parser.xmlParser())
        } catch (error: Exception) {
            throw EbookNormalizationException("Could not parse FB2 file: ${error.message}", error)
        }

        val fictionBook = document.selectFirst("FictionBook, fictionbook")
            ?: throw EbookNormalizationException("The file is not a valid FB2 document.")
        val titleInfo = fictionBook.selectFirst("description > title-info")
        val metadata = readMetadata(titleInfo)
        val resources = readResources(fictionBook)
        val resourcesById = resources.associateBy { it.sourceId }
        val chapters = buildChapters(fictionBook, resourcesById, metadata.title)
        if (chapters.isEmpty()) {
            throw EbookNormalizationException("The FB2 file did not contain readable chapters.")
        }

        destination.parentFile?.mkdirs()
        val tempFile = File(destination.parentFile ?: source.parentFile, "${destination.name}.tmp")
        if (tempFile.exists()) tempFile.delete()

        try {
            ZipOutputStream(FileOutputStream(tempFile)).use { zip ->
                zip.putStoredEntry("mimetype", "application/epub+zip".toByteArray(StandardCharsets.US_ASCII))
                zip.putDeflatedEntry("META-INF/container.xml", containerXml().toByteArray(StandardCharsets.UTF_8))
                zip.putDeflatedEntry(
                    "OEBPS/content.opf",
                    contentOpf(metadata, chapters, resources).toByteArray(StandardCharsets.UTF_8),
                )
                zip.putDeflatedEntry("OEBPS/nav.xhtml", navDocument(chapters).toByteArray(StandardCharsets.UTF_8))
                chapters.forEach { chapter ->
                    zip.putDeflatedEntry("OEBPS/${chapter.href}", chapter.content.toByteArray(StandardCharsets.UTF_8))
                }
                resources.forEach { resource ->
                    zip.putDeflatedEntry("OEBPS/${resource.href}", resource.data)
                }
            }
        } catch (error: Exception) {
            tempFile.delete()
            throw EbookNormalizationException("Could not convert FB2 file: ${error.message}", error)
        }

        if (destination.exists()) destination.delete()
        if (!tempFile.renameTo(destination)) {
            tempFile.copyTo(destination, overwrite = true)
            tempFile.delete()
        }
        return destination
    }

    private fun readMetadata(titleInfo: Element?): Metadata {
        val title = titleInfo?.selectFirst("book-title")?.text()?.trim().orEmpty().ifBlank { "Untitled" }
        val authors = titleInfo?.select("author").orEmpty().mapNotNull { author ->
            listOf("first-name", "middle-name", "last-name", "nickname")
                .mapNotNull { part -> author.selectFirst(part)?.text()?.trim()?.takeIf(String::isNotBlank) }
                .joinToString(" ")
                .takeIf(String::isNotBlank)
        }
        val coverHref = titleInfo?.selectFirst("coverpage image")?.hrefAttribute()
        return Metadata(
            title = title,
            author = authors.joinToString(", ").ifBlank { "Unknown Author" },
            publisher = titleInfo?.selectFirst("publisher")?.text()?.trim()?.takeIf(String::isNotBlank),
            language = titleInfo?.selectFirst("lang")?.text()?.trim()?.takeIf(String::isNotBlank) ?: "en",
            coverId = coverHref?.removePrefix("#")?.takeIf(String::isNotBlank),
        )
    }

    private fun readResources(fictionBook: Element): List<Resource> {
        val usedNames = mutableSetOf<String>()
        return fictionBook.select("binary[id]").mapNotNull { binary ->
            val id = binary.attr("id").trim().takeIf(String::isNotBlank) ?: return@mapNotNull null
            val mediaType = binary.attr("content-type").trim().lowercase(Locale.US)
                .takeIf(String::isNotBlank) ?: "application/octet-stream"
            val data = try {
                Base64.getMimeDecoder().decode(binary.text())
            } catch (_: IllegalArgumentException) {
                return@mapNotNull null
            }
            if (data.isEmpty()) return@mapNotNull null
            val fileName = uniqueFileName(id.safeFileName(mediaType.fileExtension()), usedNames)
            Resource(id, "resources/$fileName", mediaType, data)
        }
    }

    private fun buildChapters(
        fictionBook: Element,
        resourcesById: Map<String, Resource>,
        bookTitle: String,
    ): List<Chapter> {
        val bodies = fictionBook.children().filter { it.normalizedTagName() == "body" }
        val roots = bodies.flatMap { body ->
            body.children().filter { it.normalizedTagName() == "section" }.ifEmpty { listOf(body) }
        }
        return roots.mapIndexedNotNull { index, root ->
            val title = root.directChild("title")?.text()?.trim()
                ?.takeIf(String::isNotBlank)
                ?: if (roots.size == 1) bookTitle else "Chapter ${index + 1}"
            val body = renderChildren(root, resourcesById, headingLevel = 1).trim()
            if (body.isBlank()) return@mapIndexedNotNull null
            Chapter(
                title = title,
                href = "chapter_${index.toString().padStart(4, '0')}.xhtml",
                content = chapterDocument(title, body),
            )
        }
    }

    private fun renderChildren(element: Element, resourcesById: Map<String, Resource>, headingLevel: Int): String =
        element.childNodes().joinToString("") { node -> renderNode(node, resourcesById, headingLevel) }

    private fun renderNode(node: Node, resourcesById: Map<String, Resource>, headingLevel: Int): String = when (node) {
        is TextNode -> node.text().escapeXml()
        !is Element -> ""
        else -> {
            val children = { renderChildren(node, resourcesById, headingLevel) }
            when (node.normalizedTagName()) {
                "title" -> {
                    val level = headingLevel.coerceIn(1, 6)
                    "<h$level>${node.text().trim().escapeXml()}</h$level>"
                }
                "section" -> "<section>${renderChildren(node, resourcesById, headingLevel + 1)}</section>"
                "p" -> "<p>${children()}</p>"
                "subtitle" -> "<h${headingLevel.coerceIn(2, 6)}>${children()}</h${headingLevel.coerceIn(2, 6)}>"
                "emphasis" -> "<em>${children()}</em>"
                "strong" -> "<strong>${children()}</strong>"
                "strikethrough" -> "<s>${children()}</s>"
                "sub" -> "<sub>${children()}</sub>"
                "sup" -> "<sup>${children()}</sup>"
                "code" -> "<code>${children()}</code>"
                "a" -> {
                    val href = node.hrefAttribute()?.escapeXml().orEmpty()
                    if (href.isBlank()) children() else "<a href=\"$href\">${children()}</a>"
                }
                "image" -> {
                    val sourceId = node.hrefAttribute()?.removePrefix("#")
                    val resource = sourceId?.let(resourcesById::get)
                    resource?.let { "<figure><img src=\"${it.href.escapeXml()}\" alt=\"\"/></figure>" }.orEmpty()
                }
                "empty-line" -> "<br/>"
                "poem" -> "<section class=\"poem\">${children()}</section>"
                "stanza" -> "<div class=\"stanza\">${children()}</div>"
                "v" -> "<p class=\"verse\">${children()}</p>"
                "cite", "epigraph" -> "<blockquote>${children()}</blockquote>"
                "annotation" -> "<aside>${children()}</aside>"
                "text-author" -> "<p class=\"text-author\">${children()}</p>"
                "date" -> "<time>${children()}</time>"
                "binary", "description" -> ""
                else -> children()
            }
        }
    }

    private fun chapterDocument(title: String, body: String): String =
        """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><title>${title.escapeXml()}</title></head>
        <body>$body</body>
        </html>
        """.trimIndent()

    private fun contentOpf(metadata: Metadata, chapters: List<Chapter>, resources: List<Resource>): String {
        val cover = metadata.coverId?.let { coverId -> resources.firstOrNull { it.sourceId == coverId } }
        return buildString {
            append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
            append("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"bookid\">\n")
            append("<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n")
            append("<dc:identifier id=\"bookid\">urn:uuid:").append(UUID.randomUUID()).append("</dc:identifier>\n")
            append("<dc:title>").append(metadata.title.escapeXml()).append("</dc:title>\n")
            append("<dc:creator>").append(metadata.author.escapeXml()).append("</dc:creator>\n")
            metadata.publisher?.let { append("<dc:publisher>").append(it.escapeXml()).append("</dc:publisher>\n") }
            append("<dc:language>").append(metadata.language.escapeXml()).append("</dc:language>\n")
            append("<meta property=\"dcterms:modified\">").append(Instant.now()).append("</meta>\n")
            append("</metadata>\n<manifest>\n")
            append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n")
            chapters.forEachIndexed { index, chapter ->
                append("<item id=\"chapter_").append(index).append("\" href=\"")
                    .append(chapter.href.escapeXml()).append("\" media-type=\"application/xhtml+xml\"/>\n")
            }
            resources.forEachIndexed { index, resource ->
                append("<item id=\"resource_").append(index).append("\" href=\"")
                    .append(resource.href.escapeXml()).append("\" media-type=\"")
                    .append(resource.mediaType.escapeXml()).append("\"")
                if (resource == cover) append(" properties=\"cover-image\"")
                append("/>\n")
            }
            append("</manifest>\n<spine>\n")
            chapters.indices.forEach { index -> append("<itemref idref=\"chapter_").append(index).append("\"/>\n") }
            append("</spine>\n</package>")
        }
    }

    private fun navDocument(chapters: List<Chapter>): String = buildString {
        append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
        append("<!DOCTYPE html>\n")
        append("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">\n")
        append("<head><meta charset=\"utf-8\"/><title>Table of Contents</title></head>\n")
        append("<body><nav epub:type=\"toc\" id=\"toc\"><ol>\n")
        chapters.forEach { chapter ->
            append("<li><a href=\"").append(chapter.href.escapeXml()).append("\">")
                .append(chapter.title.escapeXml()).append("</a></li>\n")
        }
        append("</ol></nav></body>\n</html>")
    }

    private fun containerXml(): String =
        """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """.trimIndent()

    private fun Element.normalizedTagName(): String = tagName().substringAfter(':').lowercase(Locale.US)

    private fun Element.directChild(tagName: String): Element? =
        children().firstOrNull { it.normalizedTagName() == tagName }

    private fun Element.hrefAttribute(): String? =
        sequenceOf("xlink:href", "l:href", "href")
            .map(::attr)
            .firstOrNull(String::isNotBlank)

    private fun String.safeFileName(extension: String): String {
        val safe = replace(Regex("[^a-zA-Z0-9._-]"), "_").ifBlank { "resource" }
        return if (safe.contains('.')) safe else "$safe.$extension"
    }

    private fun String.fileExtension(): String = when (this) {
        "image/jpeg" -> "jpg"
        "image/png" -> "png"
        "image/gif" -> "gif"
        "image/svg+xml" -> "svg"
        else -> "bin"
    }

    private fun uniqueFileName(candidate: String, usedNames: MutableSet<String>): String {
        if (usedNames.add(candidate)) return candidate
        val base = candidate.substringBeforeLast('.', candidate)
        val extension = candidate.substringAfterLast('.', "")
        var index = 1
        while (true) {
            val next = if (extension.isBlank()) "$base-$index" else "$base-$index.$extension"
            if (usedNames.add(next)) return next
            index++
        }
    }

    private fun ZipOutputStream.putStoredEntry(name: String, data: ByteArray) {
        val checksum = CRC32().apply { update(data) }
        val entry = ZipEntry(name).apply {
            method = ZipEntry.STORED
            size = data.size.toLong()
            compressedSize = data.size.toLong()
            crc = checksum.value
        }
        putNextEntry(entry)
        write(data)
        closeEntry()
    }

    private fun ZipOutputStream.putDeflatedEntry(name: String, data: ByteArray) {
        putNextEntry(ZipEntry(name))
        write(data)
        closeEntry()
    }

    private fun String.escapeXml(): String = buildString(length) {
        for (character in this@escapeXml) {
            when (character) {
                '&' -> append("&amp;")
                '<' -> append("&lt;")
                '>' -> append("&gt;")
                '"' -> append("&quot;")
                '\'' -> append("&apos;")
                else -> append(character)
            }
        }
    }
}
