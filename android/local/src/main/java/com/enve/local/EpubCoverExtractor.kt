package com.enve.local

import android.content.Context
import android.net.Uri
import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipInputStream

object EpubCoverExtractor {

    private const val COVERS_DIR = "epub-covers"

    fun extractCoverUri(context: Context, epubUri: Uri): String? {
        val containerBytes = readZipEntry(context, epubUri) { it == "META-INF/container.xml" }
            ?: return null
        val opfPath = parseOpfPath(containerBytes) ?: return null

        val opfBytes = readZipEntry(context, epubUri) { it == opfPath } ?: return null
        val opfBaseDir = opfPath.substringBeforeLast('/', "")

        val parsedOpf = parseOpf(opfBytes) ?: return null
        val coverHref = pickCoverHref(parsedOpf) ?: return null
        val coverEntryPath = if (opfBaseDir.isEmpty()) coverHref else "$opfBaseDir/$coverHref"

        val coverBytes = readZipEntry(context, epubUri) { it == coverEntryPath } ?: return null

        val extension = coverHref.substringAfterLast('.', "jpg").lowercase()
            .let { if (it.matches(Regex("[a-z0-9]{1,5}"))) it else "jpg" }

        val coversDir = File(context.cacheDir, COVERS_DIR).apply { mkdirs() }
        val filename = "${uriHash(epubUri)}.$extension"
        val coverFile = File(coversDir, filename)
        coverFile.writeBytes(coverBytes)
        return Uri.fromFile(coverFile).toString()
    }

    private inline fun readZipEntry(
        context: Context,
        epubUri: Uri,
        match: (String) -> Boolean,
    ): ByteArray? {
        return context.contentResolver.openInputStream(epubUri)?.use { stream ->
            ZipInputStream(stream).use { zip ->
                generateSequence { zip.nextEntry }.forEach { entry ->
                    if (!entry.isDirectory && match(entry.name)) {
                        return@use zip.readBytes()
                    }
                }
                null
            }
        }
    }

    private data class ManifestItem(
        val id: String,
        val href: String,
        val mediaType: String,
        val properties: String,
    )

    private data class ParsedOpf(
        val items: List<ManifestItem>,

        val coverMetaContentId: String?,
    )

    private fun parseOpfPath(containerBytes: ByteArray): String? {
        val parser = Xml.newPullParser().apply { setInput(containerBytes.inputStream(), null) }
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            if (event == XmlPullParser.START_TAG && parser.name.substringAfterLast(':') == "rootfile") {
                return parser.getAttributeValue(null, "full-path")
            }
            event = parser.next()
        }
        return null
    }

    private fun parseOpf(opfBytes: ByteArray): ParsedOpf? {
        val parser = Xml.newPullParser().apply { setInput(opfBytes.inputStream(), null) }
        val items = mutableListOf<ManifestItem>()
        var coverMetaContentId: String? = null
        var inManifest = false

        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            val name = if (event == XmlPullParser.START_TAG || event == XmlPullParser.END_TAG) {
                parser.name.substringAfterLast(':')
            } else null

            when (event) {
                XmlPullParser.START_TAG -> when (name) {
                    "manifest" -> inManifest = true
                    "item" -> if (inManifest) {
                        val id = parser.getAttributeValue(null, "id") ?: ""
                        val href = parser.getAttributeValue(null, "href") ?: ""
                        if (href.isNotEmpty()) {
                            items.add(
                                ManifestItem(
                                    id = id,
                                    href = href,
                                    mediaType = parser.getAttributeValue(null, "media-type") ?: "",
                                    properties = parser.getAttributeValue(null, "properties") ?: "",
                                )
                            )
                        }
                    }
                    "meta" -> if (coverMetaContentId == null) {
                        val metaName = parser.getAttributeValue(null, "name")
                        if (metaName?.lowercase() == "cover") {
                            val content = parser.getAttributeValue(null, "content")
                            if (!content.isNullOrEmpty()) coverMetaContentId = content
                        }
                    }
                }
                XmlPullParser.END_TAG -> if (name == "manifest") inManifest = false
            }
            event = parser.next()
        }

        return if (items.isEmpty()) null
        else ParsedOpf(items, coverMetaContentId)
    }

    private fun pickCoverHref(opf: ParsedOpf): String? {
        val items = opf.items
        val isImage = { item: ManifestItem -> item.mediaType.lowercase().startsWith("image/") }

        items.firstOrNull { it.properties.contains("cover-image") && isImage(it) }?.let { return it.href }

        opf.coverMetaContentId?.let { coverId ->
            items.firstOrNull { it.id == coverId && isImage(it) }?.let { return it.href }
        }

        items.firstOrNull {
            val lower = it.id.lowercase()
            (lower == "cover" || lower == "cover-image") && isImage(it)
        }?.let { return it.href }

        items.firstOrNull { isImage(it) && it.href.lowercase().contains("cover") }?.let { return it.href }

        items.firstOrNull { it.properties.contains("cover-image") }?.let { return it.href }

        return null
    }

    private fun uriHash(uri: Uri): String {
        val md = MessageDigest.getInstance("SHA-1")
        val digest = md.digest(uri.toString().toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }.take(32)
    }
}
