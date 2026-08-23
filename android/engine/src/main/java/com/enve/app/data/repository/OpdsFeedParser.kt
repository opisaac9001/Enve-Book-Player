package com.enve.app.data.repository

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.BookSummary
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import java.net.URI
import java.time.OffsetDateTime

object OpdsFeedParser {

    data class ParsedPage(
        val items: List<BookSummary>,
        val nextUrl: String?,
        val navigationLinks: List<NavigationLink> = emptyList(),
        val totalResults: Int? = null,
    )

    data class NavigationLink(
        val title: String,
        val href: String,
        val rel: String,
        val type: String,
    )

    private val entryRegex = Regex("<entry\\b[\\s\\S]*?</entry>", RegexOption.IGNORE_CASE)
    private val linkRegex = Regex("<link\\b[^>]*/?>", RegexOption.IGNORE_CASE)
    private val authorBlockRegex = Regex("<author\\b[\\s\\S]*?</author>", RegexOption.IGNORE_CASE)
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    fun parse(document: String, baseUrl: String, connectionId: String): ParsedPage {
        val trimmed = document.trimStart('\uFEFF').trimStart()
        if (trimmed.startsWith("{")) {
            return parseJson(trimmed, baseUrl, connectionId)
        }
        return parseXml(document, baseUrl, connectionId)
    }

    private fun parseXml(xml: String, baseUrl: String, connectionId: String): ParsedPage {
        val items = mutableListOf<BookSummary>()
        val navigationLinks = mutableListOf<NavigationLink>()
        for (match in entryRegex.findAll(xml)) {
            val entry = match.value
            val title = extractTag(entry, "title")?.let(::decodeEntities) ?: continue
            val id = extractTag(entry, "id") ?: title
            val authors = authorBlockRegex.findAll(entry)
                .mapNotNull { extractTag(it.value, "name")?.let(::decodeEntities) }
                .toList()
            val published = extractTag(entry, "published") ?: extractTag(entry, "updated")
            val publishedMs = parseInstant(published)

            val links = linkRegex.findAll(entry).map { it.value }.toList()
            val acquisitionLink = links.firstOrNull { isAcquisition(it) }
            if (acquisitionLink == null) {
                links.firstOrNull { isNavigation(it) }?.let { link ->
                    val href = extractAttr(link, "href")?.let { resolve(baseUrl, it) } ?: return@let
                    navigationLinks += NavigationLink(
                        title = title,
                        href = href,
                        rel = extractAttr(link, "rel").orEmpty(),
                        type = extractAttr(link, "type").orEmpty(),
                    )
                }
                continue
            }
            val coverLink = links.firstOrNull { isCover(it) }
            val thumbnailLink = links.firstOrNull { isThumbnail(it) }

            val acquisitionHref = extractAttr(acquisitionLink, "href")?.let { resolve(baseUrl, it) }
            val acquisitionType = extractAttr(acquisitionLink, "type")?.lowercase() ?: ""
            val acquisitionTitle = extractAttr(acquisitionLink, "title")
            val mediaType = inferMediaType(acquisitionType, acquisitionHref, acquisitionTitle)
            val coverHref = (thumbnailLink ?: coverLink)
                ?.let { extractAttr(it, "href") }
                ?.let { resolve(baseUrl, it) }

            items += BookSummary(
                id = acquisitionHref ?: id,
                connectionId = connectionId,
                source = BookSource.OPDS,
                title = title,
                authors = authors,
                thumbnailUrl = coverHref,
                primaryFileType = inferFileType(acquisitionType, acquisitionHref, acquisitionTitle),
                mediaType = mediaType,
                addedOn = publishedMs,
                libraryId = "root",
                hasAudio = mediaType == AppMediaType.AUDIOBOOK,
                hasEbook = mediaType == AppMediaType.EBOOK,
            )
        }

        val nextHref = linkRegex.findAll(xml)
            .firstOrNull { isNext(it.value) }
            ?.let { extractAttr(it.value, "href") }
        val nextUrl = nextHref?.let { resolve(baseUrl, it) }
        val totalResults = extractTag(xml, "opensearch:totalResults")?.toIntOrNull()
        return ParsedPage(
            items = items,
            nextUrl = nextUrl,
            navigationLinks = navigationLinks,
            totalResults = totalResults,
        )
    }

    private fun parseJson(text: String, baseUrl: String, connectionId: String): ParsedPage {
        val root = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull()
            ?: return ParsedPage(emptyList(), null)
        val publications = root["publications"].arrayOrEmpty()
        val items = publications.mapNotNull { parseJsonPublication(it as? JsonObject ?: return@mapNotNull null, baseUrl, connectionId) }

        val navigationLinks = (root["navigation"].arrayOrEmpty() + root["catalogs"].arrayOrEmpty())
            .mapNotNull { parseJsonNavigation(it as? JsonObject ?: return@mapNotNull null, baseUrl) }

        val nextUrl = root["links"].arrayOrEmpty()
            .mapNotNull { it as? JsonObject }
            .firstOrNull { jsonLinkRel(it).any { rel -> rel.equals("next", ignoreCase = true) } }
            ?.get("href")
            .stringOrNull()
            ?.let { resolve(baseUrl, it) }

        val totalResults = (root["metadata"] as? JsonObject)
            ?.let { metadata ->
                metadata["numberOfItems"].intOrNull()
                    ?: metadata["totalItems"].intOrNull()
                    ?: metadata["itemsPerPage"].intOrNull()
            }

        return ParsedPage(
            items = items,
            nextUrl = nextUrl,
            navigationLinks = navigationLinks,
            totalResults = totalResults,
        )
    }

    private fun parseJsonPublication(publication: JsonObject, baseUrl: String, connectionId: String): BookSummary? {
        val metadata = publication["metadata"] as? JsonObject ?: return null
        val title = metadata["title"].stringOrNull()?.takeIf { it.isNotBlank() } ?: return null
        val links = publication["links"].arrayOrEmpty().mapNotNull { it as? JsonObject }
        val acquisitionLink = links.firstOrNull { isJsonAcquisition(it) } ?: return null
        val href = acquisitionLink["href"].stringOrNull()?.let { resolve(baseUrl, it) }
        val type = acquisitionLink["type"].stringOrNull().orEmpty()
        val formatTitle = acquisitionLink["title"].stringOrNull()
        val mediaType = inferMediaType(type, href, formatTitle)
        val image = (publication["images"].arrayOrEmpty().mapNotNull { it as? JsonObject } + links)
            .firstOrNull { isJsonThumbnail(it) }
            ?: (publication["images"].arrayOrEmpty().mapNotNull { it as? JsonObject } + links).firstOrNull { isJsonCover(it) }
        val coverHref = image?.get("href")?.stringOrNull()?.let { resolve(baseUrl, it) }
        return BookSummary(
            id = href ?: metadata["identifier"].stringOrNull() ?: title,
            connectionId = connectionId,
            source = BookSource.OPDS,
            title = title,
            authors = jsonAuthors(metadata["author"]),
            thumbnailUrl = coverHref,
            primaryFileType = inferFileType(type, href, formatTitle),
            mediaType = mediaType,
            addedOn = parseInstant(
                metadata["published"].stringOrNull()
                    ?: metadata["modified"].stringOrNull()
                    ?: metadata["updated"].stringOrNull(),
            ),
            libraryId = "root",
            hasAudio = mediaType == AppMediaType.AUDIOBOOK,
            hasEbook = mediaType == AppMediaType.EBOOK,
        )
    }

    private fun parseJsonNavigation(link: JsonObject, baseUrl: String): NavigationLink? {
        val href = link["href"].stringOrNull()?.let { resolve(baseUrl, it) } ?: return null
        return NavigationLink(
            title = link["title"].stringOrNull().orEmpty(),
            href = href,
            rel = jsonLinkRel(link).joinToString(" "),
            type = link["type"].stringOrNull().orEmpty(),
        )
    }

    fun isAcquisition(linkTag: String): Boolean {
        val rel = extractAttr(linkTag, "rel")?.lowercase().orEmpty()
        val type = extractAttr(linkTag, "type")?.lowercase().orEmpty()
        return rel.contains("acquisition") ||
            type.startsWith("application/epub") ||
            type.startsWith("application/pdf") ||
            type.contains("comicbook") ||
            type.contains("cbz") || type.contains("cbr") ||
            type.startsWith("audio/")
    }

    fun isNavigation(linkTag: String): Boolean {
        val rel = extractAttr(linkTag, "rel")?.lowercase().orEmpty()
        val type = extractAttr(linkTag, "type")?.lowercase().orEmpty()
        return rel.contains("subsection") ||
            rel.contains("collection") ||
            rel.contains("catalog") ||
            type.contains("profile=opds-catalog") ||
            type.contains("kind=navigation")
    }

    fun isCover(linkTag: String): Boolean {
        val rel = extractAttr(linkTag, "rel")?.lowercase().orEmpty()
        return rel.endsWith("/image") || rel.contains("opds-spec.org/image")
    }

    fun isThumbnail(linkTag: String): Boolean {
        val rel = extractAttr(linkTag, "rel")?.lowercase().orEmpty()
        return rel.contains("thumbnail") || rel.contains("opds-spec.org/image/thumbnail")
    }

    private fun isNext(linkTag: String): Boolean =
        extractAttr(linkTag, "rel")?.split(' ')?.any { it.equals("next", ignoreCase = true) } == true

    private fun isJsonAcquisition(link: JsonObject): Boolean {
        val rel = jsonLinkRel(link).joinToString(" ").lowercase()
        val type = link["type"].stringOrNull().orEmpty().lowercase()
        return rel.contains("acquisition") ||
            type.startsWith("application/epub") ||
            type.startsWith("application/pdf") ||
            type.contains("comicbook") ||
            type.contains("cbz") ||
            type.contains("cbr") ||
            type.startsWith("audio/")
    }

    private fun isJsonCover(link: JsonObject): Boolean {
        val rel = jsonLinkRel(link).joinToString(" ").lowercase()
        val type = link["type"].stringOrNull().orEmpty().lowercase()
        return rel.endsWith("/image") || rel.contains("cover") || type.startsWith("image/")
    }

    private fun isJsonThumbnail(link: JsonObject): Boolean {
        val rel = jsonLinkRel(link).joinToString(" ").lowercase()
        return rel.contains("thumbnail")
    }

    fun inferMediaType(mimeType: String, url: String?, titleHint: String? = null): AppMediaType {
        val hint = titleHint.orEmpty().trim().lowercase()
        if (mimeType.startsWith("audio/") || mimeType.contains("audiobook") || audioExtensions.any { hint == it }) {
            return AppMediaType.AUDIOBOOK
        }
        return when (fileExtension(url)) {
            "mp3", "m4a", "m4b", "flac", "ogg", "opus", "wav", "aac", "aax" -> AppMediaType.AUDIOBOOK
            else -> AppMediaType.EBOOK
        }
    }

    fun inferFileType(mimeType: String, url: String?, titleHint: String? = null): String? {
        titleHint?.trim()?.uppercase()?.let { hint ->
            if (hint in knownFormatHints) return hint
        }
        if (mimeType.startsWith("application/epub")) return "EPUB"
        if (mimeType.startsWith("application/pdf")) return "PDF"
        if (mimeType.contains("cbz") || mimeType.contains("comicbook")) return "CBZ"
        if (mimeType.contains("cbr")) return "CBR"
        return when (fileExtension(url)) {
            "epub" -> "EPUB"
            "pdf" -> "PDF"
            "cbz" -> "CBZ"
            "cbr" -> "CBR"
            "mp3", "m4a", "m4b", "flac", "ogg", "opus", "wav", "aac", "aax" -> "AUDIOBOOK"
            else -> null
        }
    }

    fun parseInstant(raw: String?): Long {
        if (raw.isNullOrBlank()) return 0L
        return runCatching { OffsetDateTime.parse(raw).toInstant().toEpochMilli() }
            .getOrElse { 0L }
    }

    fun extractTag(xml: String, tag: String): String? {
        val regex = Regex("<$tag\\b[^>]*>([\\s\\S]*?)</$tag>", RegexOption.IGNORE_CASE)
        return regex.find(xml)?.groupValues?.getOrNull(1)?.trim()
    }

    fun extractAttr(xmlTag: String, attr: String): String? {
        val regex = Regex("$attr=([\"'])(.*?)\\1", RegexOption.IGNORE_CASE)
        return regex.find(xmlTag)?.groupValues?.getOrNull(2)?.let(::decodeEntities)
    }

    fun decodeEntities(text: String): String =
        text.replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&apos;", "'")

    fun resolve(baseUrl: String, href: String): String {
        if (href.startsWith("http://", ignoreCase = true) || href.startsWith("https://", ignoreCase = true)) {
            return href
        }
        return runCatching { URI(baseUrl).resolve(href).toString() }
            .getOrElse { "${baseUrl.trimEnd('/')}/${href.trimStart('/')}" }
    }

    private fun fileExtension(url: String?): String? {
        val path = url?.substringBefore('?')?.substringBefore('#') ?: return null
        return path.substringAfterLast('.', "").lowercase().takeIf { it.isNotBlank() }
    }

    private fun JsonElement?.stringOrNull(): String? = (this as? JsonPrimitive)?.contentOrNull

    private fun JsonElement?.intOrNull(): Int? =
        stringOrNull()?.toIntOrNull()

    private fun JsonElement?.arrayOrEmpty(): List<JsonElement> =
        (this as? JsonArray)?.toList().orEmpty()

    private fun jsonLinkRel(link: JsonObject): List<String> {
        val rel = link["rel"]
        return when (rel) {
            is JsonArray -> rel.mapNotNull { it.stringOrNull() }
            else -> listOfNotNull(rel.stringOrNull())
        }
    }

    private fun jsonAuthors(element: JsonElement?): List<String> {
        return when (element) {
            is JsonArray -> element.mapNotNull { jsonAuthorName(it) }
            null -> emptyList()
            else -> listOfNotNull(jsonAuthorName(element))
        }
    }

    private fun jsonAuthorName(element: JsonElement): String? {
        return when (element) {
            is JsonObject -> element["name"].stringOrNull()
            else -> element.stringOrNull()
        }?.takeIf { it.isNotBlank() }
    }

    private val audioExtensions = setOf("mp3", "m4a", "m4b", "flac", "ogg", "opus", "wav", "aac", "aax")
    private val knownFormatHints = setOf("EPUB", "PDF", "CBZ", "CBR", "MP3", "M4A", "M4B", "FLAC", "OGG", "OPUS", "WAV", "AAC", "AAX")
}
