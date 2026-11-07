package com.enve.app.data.fileimport

import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.SAXException
import org.xml.sax.SAXNotRecognizedException
import org.xml.sax.SAXNotSupportedException
import org.xml.sax.ext.LexicalHandler
import org.xml.sax.helpers.DefaultHandler
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.StringReader
import java.net.URI
import java.nio.file.Paths
import java.util.zip.ZipFile
import javax.xml.parsers.SAXParserFactory

internal data class EpubPackageMetadata(
    val title: String?,
    val author: String?,
    val readAlongAvailable: Boolean,
    val coverWritten: Boolean,
)

internal object EpubPackageReader {
    private const val MAX_XML_BYTES = 4L * 1_024L * 1_024L
    private const val MAX_COVER_BYTES = 16L * 1_024L * 1_024L
    private const val DUBLIN_CORE = "http://purl.org/dc/elements/1.1/"
    private const val LEXICAL_HANDLER = "http://xml.org/sax/properties/lexical-handler"
    private val EXTERNAL_FEATURES = listOf(
        "http://xml.org/sax/features/external-general-entities",
        "http://xml.org/sax/features/external-parameter-entities",
        "http://apache.org/xml/features/nonvalidating/load-external-dtd",
    )

    fun read(epub: File, coverDestination: File): EpubPackageMetadata? {
        try {
            ZipFile(epub).use { zip ->
                val packagePath = parse(zip, "META-INF/container.xml", ContainerHandler()).packagePath ?: return null
                val opf = resolve("", packagePath) ?: return null
                val pkg = parse(zip, opf, PackageHandler())
                val baseDirectory = opf.substringBeforeLast('/', "")
                val overlays = pkg.items.filter { it.mediaType == "application/smil+xml" }.mapTo(mutableSetOf()) { it.id }
                val coverWritten = pkg.coverHref()
                    ?.let { resolve(baseDirectory, it) }
                    ?.let { writeCover(zip, it, coverDestination) } == true
                return EpubPackageMetadata(
                    title = pkg.title.normalized(),
                    author = pkg.creators.mapNotNull { it.normalized() }.distinct().joinToString(", ").ifEmpty { null },
                    readAlongAvailable = pkg.items.any { item -> item.mediaOverlay?.let(overlays::contains) == true },
                    coverWritten = coverWritten,
                )
            }
        } catch (_: IOException) {
            return null
        } catch (_: SAXException) {
            return null
        } catch (_: IllegalArgumentException) {
            return null
        }
    }

    private fun <T : DefaultHandler> parse(zip: ZipFile, path: String, handler: T): T {
        val entry = requireNotNull(zip.getEntry(path)) { "Missing $path" }
        require(!entry.isDirectory && entry.size in 1..MAX_XML_BYTES)
        val reader = SAXParserFactory.newInstance().apply { isNamespaceAware = true }.newSAXParser().xmlReader
        EXTERNAL_FEATURES.forEach { feature ->
            try {
                reader.setFeature(feature, false)
            } catch (_: SAXNotRecognizedException) {
            } catch (_: SAXNotSupportedException) {
            }
        }
        reader.setProperty(LEXICAL_HANDLER, DocumentTypeRejector)
        reader.contentHandler = handler
        reader.entityResolver = handler
        reader.errorHandler = handler
        zip.getInputStream(entry).use { input -> reader.parse(InputSource(input.bounded(MAX_XML_BYTES))) }
        return handler
    }

    private object DocumentTypeRejector : LexicalHandler {
        override fun startDTD(name: String?, publicId: String?, systemId: String?) {
            throw SAXException("Document type declarations are not allowed")
        }

        override fun endDTD() = Unit
        override fun startEntity(name: String?) = Unit
        override fun endEntity(name: String?) = Unit
        override fun startCDATA() = Unit
        override fun endCDATA() = Unit
        override fun comment(ch: CharArray?, start: Int, length: Int) = Unit
    }

    private fun writeCover(zip: ZipFile, path: String, destination: File): Boolean {
        val entry = zip.getEntry(path) ?: return false
        if (entry.isDirectory || entry.size !in 1..MAX_COVER_BYTES) return false
        val staged = File(destination.parentFile, "${destination.name}.part")
        zip.getInputStream(entry).use { input ->
            staged.outputStream().use { output -> input.bounded(MAX_COVER_BYTES).copyTo(output) }
        }
        if (!staged.renameTo(destination)) {
            staged.delete()
            return false
        }
        return true
    }

    internal fun resolve(baseDirectory: String, href: String): String? {
        val uri = try {
            URI(href.substringBefore('#'))
        } catch (_: java.net.URISyntaxException) {
            return null
        }
        if (uri.isAbsolute || uri.rawAuthority != null || uri.path.isNullOrEmpty()) return null
        val relative = Paths.get(uri.path)
        if (relative.isAbsolute) return null
        val resolved = Paths.get(baseDirectory).resolve(relative).normalize()
        if (resolved.startsWith("..") || resolved.toString().isEmpty()) return null
        return resolved.toString().replace(File.separatorChar, '/')
    }

    private fun String?.normalized(): String? = this?.replace(Regex("\\s+"), " ")?.trim()?.takeIf { it.isNotEmpty() }

    private fun InputStream.bounded(limit: Long): InputStream = object : InputStream() {
        private var remaining = limit
        override fun read(): Int {
            if (remaining <= 0L) throw IOException("Entry exceeds $limit bytes")
            return this@bounded.read().also { if (it >= 0) remaining-- }
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (remaining <= 0L) throw IOException("Entry exceeds $limit bytes")
            val count = this@bounded.read(buffer, offset, minOf(length.toLong(), remaining).toInt())
            if (count > 0) remaining -= count
            return count
        }

        override fun close() = this@bounded.close()
    }

    private open class SafeHandler : DefaultHandler() {
        override fun resolveEntity(publicId: String?, systemId: String?): InputSource = InputSource(StringReader(""))
    }

    private class ContainerHandler : SafeHandler() {
        var packagePath: String? = null

        override fun startElement(uri: String, localName: String, qName: String, attributes: Attributes) {
            if (packagePath == null && localName == "rootfile") packagePath = attributes.getValue("full-path")
        }
    }

    private data class ManifestItem(
        val id: String,
        val href: String,
        val mediaType: String,
        val properties: String,
        val mediaOverlay: String?,
    )

    private class PackageHandler : SafeHandler() {
        val items = mutableListOf<ManifestItem>()
        val creators = mutableListOf<String>()
        var title: String? = null
        private var coverId: String? = null
        private var text: StringBuilder? = null

        override fun startElement(uri: String, localName: String, qName: String, attributes: Attributes) {
            when {
                uri == DUBLIN_CORE && (localName == "title" || localName == "creator") -> text = StringBuilder()
                localName == "item" -> {
                    val href = attributes.getValue("href") ?: return
                    items += ManifestItem(
                        id = attributes.getValue("id").orEmpty(),
                        href = href,
                        mediaType = attributes.getValue("media-type").orEmpty().lowercase(),
                        properties = attributes.getValue("properties").orEmpty(),
                        mediaOverlay = attributes.getValue("media-overlay"),
                    )
                }
                localName == "meta" && attributes.getValue("name").equals("cover", ignoreCase = true) ->
                    if (coverId == null) coverId = attributes.getValue("content")
            }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            text?.takeIf { it.length < 2_048 }?.append(ch, start, length)
        }

        override fun endElement(uri: String, localName: String, qName: String) {
            if (uri != DUBLIN_CORE) return
            val value = text?.toString() ?: return
            text = null
            when (localName) {
                "title" -> if (title == null) title = value
                "creator" -> creators += value
            }
        }

        fun coverHref(): String? {
            val images = items.filter { it.mediaType.startsWith("image/") }
            return images.firstOrNull { "cover-image" in it.properties.split(' ') }?.href
                ?: coverId?.let { id -> images.firstOrNull { it.id == id }?.href }
                ?: images.firstOrNull { it.id.equals("cover", true) || it.id.equals("cover-image", true) }?.href
                ?: images.firstOrNull { it.href.contains("cover", ignoreCase = true) }?.href
        }
    }
}
