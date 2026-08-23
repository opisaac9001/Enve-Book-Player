package com.enve.app.document

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.jsoup.Jsoup
import org.jsoup.nodes.Entities
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.Locale
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class NativeKindleEpubConverter(context: Context) : KindleEpubConverter {
    private val appContext = context.applicationContext

    class ParsedKindleBook(
        val title: String?,
        val author: String?,
        val publisher: String?,
        val language: String?,
        val rawHtmlBytes: ByteArray,
        val resources: Array<ParsedKindleResource>,
        val toc: Array<ParsedKindleTocEntry>?,
        val coverResourceUid: Int,
    )

    class ParsedKindleResource(
        val uid: Int,
        val path: String,
        val data: ByteArray,
        val mediaType: String,
    )

    class ParsedKindleTocEntry(
        val title: String,
        val filePosition: Int,
    )

    private data class EpubResource(
        val uid: Int,
        val sourcePath: String,
        val href: String,
        val data: ByteArray,
        val mediaType: String,
    )

    private data class EpubChapter(
        val title: String,
        val href: String,
        val content: String,
    )

    private external fun parseKindleFile(filePath: String): ParsedKindleBook?

    override suspend fun convertToEpub(source: File, destination: File): File = withContext(Dispatchers.IO) {
        val parsed = try {
            parseKindleFile(source.absolutePath)
        } catch (error: UnsatisfiedLinkError) {
            throw EbookNormalizationException("Native Kindle converter is not available on this device.", error)
        } catch (error: Throwable) {
            throw EbookNormalizationException("Could not parse Kindle file: ${error.message}", error)
        } ?: throw EbookNormalizationException("Could not parse this Kindle file. DRM-protected Kindle files are not supported.")

        val rawHtml = parsed.rawHtmlBytes.toString(StandardCharsets.UTF_8)
        if (rawHtml.isBlank()) {
            throw EbookNormalizationException("The Kindle file did not contain readable HTML content.")
        }

        val resources = buildEpubResources(parsed.resources)
        val chapters = buildChapters(parsed, rawHtml, resources)
        if (chapters.isEmpty()) {
            throw EbookNormalizationException("The Kindle file did not contain readable chapters.")
        }

        destination.parentFile?.mkdirs()
        val tempFile = File(destination.parentFile ?: appContext.cacheDir, "${destination.name}.tmp")
        if (tempFile.exists()) tempFile.delete()

        ZipOutputStream(FileOutputStream(tempFile)).use { zip ->
            zip.putStoredEntry("mimetype", "application/epub+zip".toByteArray(StandardCharsets.US_ASCII))
            zip.putDeflatedEntry("META-INF/container.xml", containerXml().toByteArray(StandardCharsets.UTF_8))
            zip.putDeflatedEntry("OEBPS/content.opf", contentOpf(parsed, chapters, resources).toByteArray(StandardCharsets.UTF_8))
            zip.putDeflatedEntry("OEBPS/nav.xhtml", navDocument(chapters).toByteArray(StandardCharsets.UTF_8))
            chapters.forEach { chapter ->
                zip.putDeflatedEntry("OEBPS/${chapter.href}", chapter.content.toByteArray(StandardCharsets.UTF_8))
            }
            resources.forEach { resource ->
                zip.putDeflatedEntry("OEBPS/${resource.href}", resource.data)
            }
        }

        if (destination.exists()) destination.delete()
        if (!tempFile.renameTo(destination)) {
            tempFile.copyTo(destination, overwrite = true)
            tempFile.delete()
        }
        destination
    }

    private fun buildEpubResources(resources: Array<ParsedKindleResource>): List<EpubResource> {
        val usedNames = mutableSetOf<String>()
        return resources
            .filter { it.data.isNotEmpty() }
            .mapIndexed { index, resource ->
                val fileName = uniqueFileName(resource.path.safeArchiveLeafName(index), usedNames)
                EpubResource(
                    uid = resource.uid,
                    sourcePath = resource.path,
                    href = "resources/$fileName",
                    data = resource.data,
                    mediaType = resource.mediaType.normalizedMediaType(),
                )
            }
    }

    private fun buildChapters(
        parsed: ParsedKindleBook,
        rawHtml: String,
        resources: List<EpubResource>,
    ): List<EpubChapter> {
        val rawBytes = parsed.rawHtmlBytes
        val chapterDrafts = mutableListOf<Pair<String, String>>()
        val tocEntries = parsed.toc
            ?.filter { it.filePosition in 0 until rawBytes.size }
            ?.distinctBy { it.filePosition }
            ?.sortedBy { it.filePosition }
            .orEmpty()

        if (tocEntries.isNotEmpty()) {
            tocEntries.forEachIndexed { index, entry ->
                val start = entry.filePosition
                val end = tocEntries.getOrNull(index + 1)?.filePosition ?: rawBytes.size
                if (start < end) {
                    val chapterHtml = rawBytes.copyOfRange(start, end).toString(StandardCharsets.UTF_8)
                    if (chapterHtml.isNotBlank()) {
                        chapterDrafts += (entry.title.ifBlank { "Chapter ${index + 1}" } to chapterHtml)
                    }
                }
            }
        }

        if (chapterDrafts.isEmpty()) {
            val parts = pageBreakRegex.split(rawHtml).filter { it.isNotBlank() }
            if (parts.isNotEmpty()) {
                parts.forEachIndexed { index, html -> chapterDrafts += "Chapter ${index + 1}" to html }
            } else {
                chapterDrafts += ((parsed.title ?: "Chapter 1") to rawHtml)
            }
        }

        val rewriteContext = ResourceRewriteContext(resources)
        return chapterDrafts.mapIndexed { index, (title, html) ->
            EpubChapter(
                title = title,
                href = "chapter_${index.toString().padStart(4, '0')}.xhtml",
                content = rewriteChapterHtml(title, html, rewriteContext),
            )
        }
    }

    private fun rewriteChapterHtml(title: String, html: String, context: ResourceRewriteContext): String {
        val doc = Jsoup.parse(html.replace(pageBreakRegex, ""))
        doc.outputSettings()
            .syntax(org.jsoup.nodes.Document.OutputSettings.Syntax.xml)
            .escapeMode(Entities.EscapeMode.xhtml)
            .prettyPrint(false)

        doc.select("script").remove()

        doc.select("link[href]").forEach { link ->
            val href = link.attr("href")
            val rewritten = context.mapKindleFlow(href) ?: context.mapKnownResourceReference(href)
            if (rewritten != null) {
                link.attr("href", rewritten)
            }
        }

        doc.select("[src]").forEach { element ->
            val source = element.attr("src")
            val rewritten = context.mapKindleImage(source)
                ?: context.mapKnownResourceReference(source)
                ?: element.attr("recindex").toIntOrNull()?.let { context.mapSequentialImage(it) }
            if (rewritten != null) {
                element.attr("src", rewritten)
                element.removeAttr("recindex")
            }
        }

        val stylesheetHrefs = doc.select("link[href]")
            .mapNotNull { link -> link.attr("href").takeIf { it.endsWith(".css", ignoreCase = true) } }
            .distinct()
        doc.select("link[href]").remove()

        val bodyHtml = doc.body().html().takeIf { it.isNotBlank() } ?: doc.html()
        val styleLinks = stylesheetHrefs.joinToString("\n") { href ->
            "<link rel=\"stylesheet\" type=\"text/css\" href=\"${href.escapeXml()}\"/>"
        }

        return buildString {
            append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
            append("<!DOCTYPE html>\n")
            append("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">\n")
            append("<head>\n<meta charset=\"utf-8\"/>\n")
            append("<title>").append(title.escapeXml()).append("</title>\n")
            if (styleLinks.isNotBlank()) append(styleLinks).append('\n')
            append("</head>\n<body>\n")
            append(bodyHtml)
            append("\n</body>\n</html>")
        }
    }

    private fun contentOpf(
        parsed: ParsedKindleBook,
        chapters: List<EpubChapter>,
        resources: List<EpubResource>,
    ): String {
        val identifier = "urn:uuid:${UUID.randomUUID()}"
        val title = parsed.title?.takeIf { it.isNotBlank() } ?: "Untitled"
        val author = parsed.author?.takeIf { it.isNotBlank() } ?: "Unknown Author"
        val language = parsed.language?.takeIf { it.isNotBlank() } ?: "en"
        val modified = Instant.now().toString()
        val cover = resources.firstOrNull { it.uid == parsed.coverResourceUid && it.mediaType.startsWith("image/") }

        return buildString {
            append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
            append("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"bookid\">\n")
            append("<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n")
            append("<dc:identifier id=\"bookid\">").append(identifier.escapeXml()).append("</dc:identifier>\n")
            append("<dc:title>").append(title.escapeXml()).append("</dc:title>\n")
            append("<dc:creator>").append(author.escapeXml()).append("</dc:creator>\n")
            parsed.publisher?.takeIf { it.isNotBlank() }?.let {
                append("<dc:publisher>").append(it.escapeXml()).append("</dc:publisher>\n")
            }
            append("<dc:language>").append(language.escapeXml()).append("</dc:language>\n")
            append("<meta property=\"dcterms:modified\">").append(modified.escapeXml()).append("</meta>\n")
            append("</metadata>\n")
            append("<manifest>\n")
            append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n")
            chapters.forEachIndexed { index, chapter ->
                append("<item id=\"chapter_").append(index).append("\" href=\"").append(chapter.href.escapeXml())
                    .append("\" media-type=\"application/xhtml+xml\"/>\n")
            }
            resources.forEachIndexed { index, resource ->
                append("<item id=\"res_").append(index).append("\" href=\"").append(resource.href.escapeXml())
                    .append("\" media-type=\"").append(resource.mediaType.escapeXml()).append("\"")
                if (resource == cover) append(" properties=\"cover-image\"")
                append("/>\n")
            }
            append("</manifest>\n")
            append("<spine>\n")
            chapters.indices.forEach { index -> append("<itemref idref=\"chapter_").append(index).append("\"/>\n") }
            append("</spine>\n")
            append("</package>")
        }
    }

    private fun navDocument(chapters: List<EpubChapter>): String = buildString {
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

    private class ResourceRewriteContext(resources: List<EpubResource>) {
        private val imageResources = resources
            .filter { it.mediaType.startsWith("image/") }
            .sortedBy { it.uid }

        private val imagesByUid = imageResources.associate { it.uid to it.href }

        private val resourcesByUid = resources.associate { it.uid to it.href }

        private val resourcesByLeafName = resources.associate { leafName(it.sourcePath) to it.href }

        private val imagesBySequenceOneBased = imageResources
            .mapIndexed { index, resource -> index + 1 to resource.href }
            .toMap()

        private val imagesBySequenceZeroBased = imageResources
            .mapIndexed { index, resource -> index to resource.href }
            .toMap()

        private val cssByFlowIndex = resources
            .filter { it.mediaType == "text/css" && it.sourcePath.startsWith("flow_", ignoreCase = true) }
            .mapNotNull { resource ->
                resource.sourcePath.substringAfter("flow_", "").substringBefore('.').toIntOrNull()?.let { it to resource.href }
            }
            .toMap()

        fun mapSequentialImage(index: Int): String? {
            return imagesByUid[index]
                ?: imagesBySequenceOneBased[index]
                ?: imagesBySequenceZeroBased[index]
        }

        fun mapKnownResourceReference(value: String): String? {
            val payload = value.trim().trim('"', '\'', ' ')
            if (payload.isBlank()) return null
            val leaf = leafName(payload.substringBefore('#').substringBefore('?'))

            parseUidAfterPrefix(leaf, "resource")?.let { uid ->
                resourcesByUid[uid]?.let { return it }
            }
            parseUidAfterPrefix(leaf, "res_")?.let { uid ->
                resourcesByUid[uid]?.let { return it }
            }
            parseUidAfterPrefix(leaf, "flow")?.let { index ->
                cssByFlowIndex[index]?.let { return it }
            }
            parseUidAfterPrefix(leaf, "flow_")?.let { index ->
                cssByFlowIndex[index]?.let { return it }
            }

            return resourcesByLeafName[leaf]
        }

        fun mapKindleImage(value: String): String? {
            val payload = value.trim().trim('"', '\'', ' ')
            if (!payload.startsWith("kindle:embed:", ignoreCase = true)) return null
            val token = payload.substringAfter("kindle:embed:").substringBefore('?').trim()
            val decimalIndex = token.toIntOrNull()
            val base32Index = decodeKindleBase32(token.take(4))?.minus(1)
            return decimalIndex?.let { mapSequentialImage(it) }
                ?: base32Index?.let { mapSequentialImage(it) }
        }

        fun mapKindleFlow(value: String): String? {
            val payload = value.trim().trim('"', '\'', ' ')
            if (!payload.startsWith("kindle:flow:", ignoreCase = true)) return null
            val token = payload.substringAfter("kindle:flow:").substringBefore('?').trim()
            val decimalIndex = token.toIntOrNull()
            val base32Index = decodeKindleBase32(token.take(4))
            return decimalIndex?.let { cssByFlowIndex[it] }
                ?: base32Index?.let { cssByFlowIndex[it] }
        }

        private fun decodeKindleBase32(value: String): Int? {
            if (value.isBlank() || value.length > 6) return null
            var result = 0
            value.uppercase(Locale.US).forEach { ch ->
                val digit = when (ch) {
                    in '0'..'9' -> ch - '0'
                    in 'A'..'V' -> ch - 'A' + 10
                    else -> return null
                }
                result = (result * 32) + digit
            }
            return result
        }

        private fun parseUidAfterPrefix(value: String, prefix: String): Int? {
            if (!value.startsWith(prefix, ignoreCase = true)) return null
            val digits = value.substring(prefix.length).takeWhile { it.isDigit() }
            return digits.toIntOrNull()
        }

        private fun leafName(value: String): String = value.replace('\\', '/').substringAfterLast('/').lowercase(Locale.US)
    }

    private fun ZipOutputStream.putStoredEntry(name: String, data: ByteArray) {
        val crc = CRC32().apply { update(data) }
        val entry = ZipEntry(name).apply {
            method = ZipEntry.STORED
            size = data.size.toLong()
            compressedSize = data.size.toLong()
            this.crc = crc.value
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

    private fun String.safeArchiveLeafName(index: Int): String {
        val leaf = replace('\\', '/').substringAfterLast('/').ifBlank { "resource_$index.bin" }
        return leaf.replace(Regex("[^a-zA-Z0-9._-]"), "_").ifBlank { "resource_$index.bin" }
    }

    private fun String.normalizedMediaType(): String {
        val value = trim().lowercase(Locale.US)
        return when {
            value.isBlank() -> "application/octet-stream"
            value == "image/jpg" -> "image/jpeg"
            else -> value
        }
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

    private fun String.escapeXml(): String = buildString(length) {
        for (char in this@escapeXml) {
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

    companion object {
        private val pageBreakRegex = Regex("(?i)<mbp:pagebreak\\s*/?>")

        init {
            System.loadLibrary("mobi")
            System.loadLibrary("enve_mobi")
        }
    }
}
