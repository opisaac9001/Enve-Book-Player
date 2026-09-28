package com.enve.app.data.repository

import com.enve.app.data.opds.OPDS_PROGRESSION_MEDIA_TYPE
import com.enve.app.data.opds.OPDS_PROGRESSION_REL
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.BookSummary
import com.enve.core.data.util.objects
import com.enve.core.data.util.stringOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.parser.Parser
import java.net.URI
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.util.Locale
import kotlin.math.roundToLong

object OpdsFeedParser {

    data class ParsedPage(
        val items: List<BookSummary>,
        val nextUrl: String?,
        val navigationLinks: List<NavigationLink> = emptyList(),
        val totalResults: Int? = null,
        val title: String? = null,
        val selfUrl: String? = null,
        val previousUrl: String? = null,
        val firstUrl: String? = null,
        val lastUrl: String? = null,
        val itemsPerPage: Int? = null,
        val currentPage: Int? = null,
        val publications: List<OpdsPublication> = emptyList(),
        val groups: List<OpdsGroup> = emptyList(),
        val facets: List<OpdsFacet> = emptyList(),
        val searchLinks: List<OpdsSearchLink> = emptyList(),
        val isSinglePublicationDocument: Boolean = false,
    ) {
        val allNavigationLinks: List<NavigationLink>
            get() = (navigationLinks + groups.flatMap { it.navigationLinks }).distinctBy { it.href }
    }

    data class NavigationLink(
        val title: String,
        val href: String,
        val rel: String,
        val type: String,
        val numberOfItems: Int? = null,
    )

    private val schemeRegex = Regex("^[A-Za-z][A-Za-z0-9+.-]*:")
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private const val OPDS_PREFIX = "http://opds-spec.org/"
    private const val ADEPT_TYPE = "application/vnd.adobe.adept+xml"
    private const val OPDS_AUTH_DOCUMENT_REL = "http://opds-spec.org/auth/document"
    private val BYTE_ORDER_MARK = 0xFEFF.toChar()

    fun parse(document: String, baseUrl: String, connectionId: String): ParsedPage {
        val trimmed = document.trimStart(BYTE_ORDER_MARK).trimStart()
        if (trimmed.startsWith("{")) {
            return parseJson(trimmed, baseUrl, connectionId)
        }
        return parseXml(trimmed, baseUrl, connectionId)
    }

    private fun parseXml(xml: String, baseUrl: String, connectionId: String): ParsedPage {
        val root = Jsoup.parse(xml, baseUrl, Parser.xmlParser()).children()
            .firstOrNull { it.isNamed("feed") || it.isNamed("entry") }
            ?: return ParsedPage(emptyList(), null)
        val isEntryDocument = root.isNamed("entry")
        val entries = if (isEntryDocument) listOf(root) else root.childrenNamed("entry")
        val feedLinks = root.childrenNamed("link")
        val feedAuthenticateUrl = xmlAuthenticateUrl(feedLinks, baseUrl)

        val publications = mutableListOf<OpdsPublication>()
        val navigationLinks = mutableListOf<NavigationLink>()

        for (entry in entries) {
            val title = entry.textOf("title") ?: continue
            val links = entry.childrenNamed("link")
            val acquisitions = links.mapNotNull { xmlAcquisition(it, baseUrl) }
            if (acquisitions.isEmpty()) {
                xmlNavigation(title, links, baseUrl)?.let { navigationLinks += it }
                continue
            }

            val identifier = entry.textOf("id")
            val selected = selectAcquisition(acquisitions)
            val selfUrl = links.firstOrNull { relTokens(it.attrAny("rel")).contains("self") }
                ?.let { httpResolve(baseUrl, it.attrAny("href")) }
            val id = identifier ?: selfUrl ?: selected?.href ?: title
            val progressionUrl = links
                .firstOrNull { isProgressionLink(relTokens(it.attrAny("rel")), it.attrAny("type")) }
                ?.let { httpResolve(baseUrl, it.attrAny("href")) }

            publications += OpdsPublication(
                id = id,
                identifier = identifier,
                selfUrl = selfUrl,
                summary = BookSummary(
                    id = id,
                    connectionId = connectionId,
                    source = BookSource.OPDS,
                    title = title,
                    description = entry.textOf("summary") ?: entry.textOf("content"),
                    authors = entry.childrenNamed("author").mapNotNull { it.textOf("name") },
                    thumbnailUrl = xmlCoverUrl(links, baseUrl),
                    primaryFileType = selected?.let { fileTypeFor(it) },
                    mediaType = selected?.let { mediaTypeFor(it) } ?: AppMediaType.EBOOK,
                    addedOn = parseInstant(entry.textOf("published") ?: entry.textOf("updated")),
                    libraryId = "root",
                    hasAudio = hasMedia(acquisitions, AppMediaType.AUDIOBOOK),
                    hasEbook = hasMedia(acquisitions, AppMediaType.EBOOK),
                    isbn13 = isbn13Of(entry.textOf("identifier") ?: identifier),
                    publisher = entry.textOf("publisher"),
                    publishedDate = entry.textOf("issued") ?: entry.textOf("published"),
                    language = entry.textOf("language"),
                    categories = entry.childrenNamed("category").mapNotNull { it.attrAny("label") ?: it.attrAny("term") },
                    opdsAcquisitionUrl = selected?.downloadHref,
                    opdsProgressionUrl = progressionUrl,
                ),
                acquisitions = acquisitions,
                selectedAcquisition = selected,
                progressionUrl = progressionUrl,
                progressionAuthenticateUrl = progressionUrl
                    ?.let { xmlAuthenticateUrl(links, baseUrl) ?: feedAuthenticateUrl },
            )
        }

        val feedRel = { rel: String ->
            feedLinks.firstOrNull { relTokens(it.attrAny("rel")).contains(rel) }
                ?.let { httpResolve(baseUrl, it.attrAny("href")) }
        }

        return ParsedPage(
            items = listedSummaries(publications),
            nextUrl = feedRel("next"),
            navigationLinks = navigationLinks,
            totalResults = root.textOf("totalResults")?.toIntOrNull(),
            title = root.textOf("title"),
            selfUrl = feedRel("self"),
            previousUrl = feedRel("previous") ?: feedRel("prev"),
            firstUrl = feedRel("first"),
            lastUrl = feedRel("last"),
            itemsPerPage = root.textOf("itemsPerPage")?.toIntOrNull(),
            publications = publications,
            facets = feedLinks.mapNotNull { xmlFacet(it, baseUrl) },
            searchLinks = feedLinks.mapNotNull { xmlSearchLink(it, baseUrl) },
            isSinglePublicationDocument = isEntryDocument && publications.isNotEmpty(),
        )
    }

    private fun xmlAuthenticateUrl(links: List<Element>, baseUrl: String): String? =
        links.firstOrNull { link ->
            relTokens(link.attrAny("rel")).any { it.equals(OPDS_AUTH_DOCUMENT_REL, ignoreCase = true) }
        }?.let { httpResolve(baseUrl, it.attrAny("href")) }

    private fun xmlAcquisition(link: Element, baseUrl: String): OpdsAcquisition? {
        val mediaType = link.attrAny("type").orEmpty()
        val kind = acquisitionKindFor(relTokens(link.attrAny("rel")), mediaType) ?: return null
        val href = httpResolve(baseUrl, link.attrAny("href")) ?: return null
        return buildAcquisition(
            kind = kind,
            href = href,
            mediaType = mediaType,
            title = link.attrAny("title"),
            indirect = xmlIndirect(link),
            price = link.childNamed("price")?.let { node ->
                node.text().trim().toDoubleOrNull()
                    ?.let { OpdsPrice(currency = node.attrAny("currencycode"), value = it) }
            },
            availability = link.childNamed("availability")?.let {
                OpdsAvailability(
                    state = it.attrAny("status"),
                    since = it.attrAny("since"),
                    until = it.attrAny("until"),
                )
            },
            copies = link.childNamed("copies")?.let {
                OpdsCopies(total = it.attrAny("total")?.toIntOrNull(), available = it.attrAny("available")?.toIntOrNull())
            },
            holds = link.childNamed("holds")?.let {
                OpdsHolds(total = it.attrAny("total")?.toIntOrNull(), position = it.attrAny("position")?.toIntOrNull())
            },
        )
    }

    private fun xmlIndirect(element: Element): List<OpdsIndirectAcquisition> =
        element.childrenNamed("indirectAcquisition").map {
            OpdsIndirectAcquisition(it.attrAny("type").orEmpty(), xmlIndirect(it))
        }

    private fun xmlNavigation(title: String, links: List<Element>, baseUrl: String): NavigationLink? {
        val link = links.firstOrNull {
            isNavigationLink(it.attrAny("rel").orEmpty(), it.attrAny("type").orEmpty())
        } ?: return null
        val href = httpResolve(baseUrl, link.attrAny("href")) ?: return null
        return NavigationLink(
            title = title,
            href = href,
            rel = link.attrAny("rel").orEmpty(),
            type = link.attrAny("type").orEmpty(),
            numberOfItems = link.attrAny("count")?.toIntOrNull(),
        )
    }

    private fun xmlCoverUrl(links: List<Element>, baseUrl: String): String? =
        (links.firstOrNull { isThumbnailRel(it.attrAny("rel").orEmpty()) }
            ?: links.firstOrNull { isCoverRel(it.attrAny("rel").orEmpty()) })
            ?.let { httpResolve(baseUrl, it.attrAny("href")) }

    private fun xmlFacet(link: Element, baseUrl: String): OpdsFacet? {
        if (!relTokens(link.attrAny("rel")).any { it == "${OPDS_PREFIX}facet" || it == "facet" }) return null
        val href = httpResolve(baseUrl, link.attrAny("href")) ?: return null
        return OpdsFacet(
            groupTitle = link.attrAny("facetGroup").orEmpty(),
            title = link.attrAny("title").orEmpty(),
            href = href,
            type = link.attrAny("type").orEmpty(),
            numberOfItems = link.attrAny("count")?.toIntOrNull(),
            isActive = link.attrAny("activeFacet")?.equals("true", ignoreCase = true) == true,
        )
    }

    private fun xmlSearchLink(link: Element, baseUrl: String): OpdsSearchLink? {
        if (!relTokens(link.attrAny("rel")).contains("search")) return null
        val href = httpResolve(baseUrl, link.attrAny("href")) ?: return null
        return OpdsSearchLink(
            href = href,
            type = link.attrAny("type").orEmpty(),
            title = link.attrAny("title"),
            templated = href.contains('{'),
        )
    }

    private fun parseJson(text: String, baseUrl: String, connectionId: String): ParsedPage {
        val root = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull()
            ?: return ParsedPage(emptyList(), null)
        val metadata = root["metadata"] as? JsonObject
        val links = root["links"].objects()

        val listed = root["publications"].objects()
            .mapNotNull { parseJsonPublication(it, baseUrl, connectionId) }
        val single = if (listed.isEmpty()) parseJsonSinglePublication(root, baseUrl, connectionId) else null
        val publications = listed.ifEmpty { listOfNotNull(single) }
        val groups = root["groups"].objects().map { parseJsonGroup(it, baseUrl, connectionId) }
        val allPublications = (publications + groups.flatMap { it.publications }).distinctBy { it.id }

        val navigationLinks = root["navigation"].objects().mapNotNull { parseJsonNavigation(it, baseUrl) } +
            root["catalogs"].objects().mapNotNull { parseJsonCatalog(it, baseUrl) }

        val linkRel = { rel: String ->
            links.firstOrNull { jsonLinkRel(it).any { value -> value.equals(rel, ignoreCase = true) } }
                ?.let { httpResolve(baseUrl, it["href"].stringOrNull()) }
        }

        return ParsedPage(
            items = listedSummaries(allPublications),
            nextUrl = linkRel("next"),
            navigationLinks = navigationLinks,
            totalResults = metadata?.let { it["numberOfItems"].intOrNull() ?: it["totalItems"].intOrNull() },
            title = localizedString(metadata?.get("title")),
            selfUrl = linkRel("self"),
            previousUrl = linkRel("previous") ?: linkRel("prev"),
            firstUrl = linkRel("first"),
            lastUrl = linkRel("last"),
            itemsPerPage = metadata?.get("itemsPerPage").intOrNull(),
            currentPage = metadata?.get("currentPage").intOrNull(),
            publications = allPublications,
            groups = groups,
            facets = root["facets"].objects().flatMap { parseJsonFacetGroup(it, baseUrl) },
            searchLinks = links.mapNotNull { parseJsonSearchLink(it, baseUrl) },
            isSinglePublicationDocument = single != null,
        )
    }

    private fun parseJsonSinglePublication(
        root: JsonObject,
        baseUrl: String,
        connectionId: String,
    ): OpdsPublication? {
        if (root["metadata"] !is JsonObject) return null
        if (root.containsKey("navigation") || root.containsKey("groups") || root.containsKey("catalogs")) return null
        return parseJsonPublication(root, baseUrl, connectionId)
    }

    private fun parseJsonGroup(group: JsonObject, baseUrl: String, connectionId: String): OpdsGroup {
        val metadata = group["metadata"] as? JsonObject
        val links = group["links"].objects()
        return OpdsGroup(
            title = localizedString(metadata?.get("title")).orEmpty(),
            selfUrl = links.firstOrNull { jsonLinkRel(it).any { rel -> rel.equals("self", ignoreCase = true) } }
                ?.let { httpResolve(baseUrl, it["href"].stringOrNull()) },
            navigationLinks = group["navigation"].objects().mapNotNull { parseJsonNavigation(it, baseUrl) },
            publications = group["publications"].objects().mapNotNull { parseJsonPublication(it, baseUrl, connectionId) },
        )
    }

    private fun parseJsonPublication(publication: JsonObject, baseUrl: String, connectionId: String): OpdsPublication? {
        val metadata = publication["metadata"] as? JsonObject ?: return null
        val title = localizedString(metadata["title"]) ?: return null
        val links = publication["links"].objects()
        val acquisitions = links.mapNotNull { jsonAcquisition(it, baseUrl) }
        val selected = selectAcquisition(acquisitions)
        val identifier = metadata["identifier"].stringOrNull()?.takeIf { it.isNotBlank() }
        val selfUrl = links.firstOrNull { jsonLinkRel(it).any { rel -> rel.equals("self", ignoreCase = true) } }
            ?.let { httpResolve(baseUrl, it["href"].stringOrNull()) }
        val id = identifier ?: selfUrl ?: selected?.href ?: return null
        val series = jsonSeries(metadata["belongsTo"] ?: metadata["belongs_to"])
        val progressionLink = links
            .firstOrNull { isProgressionLink(jsonLinkRel(it), it["type"].stringOrNull()) }
        val progressionUrl = progressionLink?.let { httpResolve(baseUrl, it["href"].stringOrNull()) }

        return OpdsPublication(
            id = id,
            identifier = identifier,
            selfUrl = selfUrl,
            summary = BookSummary(
                id = id,
                connectionId = connectionId,
                source = BookSource.OPDS,
                title = title,
                subtitle = localizedString(metadata["subtitle"]),
                description = localizedString(metadata["description"]),
                authors = jsonAuthors(metadata["author"]),
                thumbnailUrl = jsonCoverUrl(publication, links, baseUrl),
                seriesName = series?.first,
                seriesNumber = series?.second,
                primaryFileType = selected?.let { fileTypeFor(it) },
                mediaType = selected?.let { mediaTypeFor(it) } ?: AppMediaType.EBOOK,
                addedOn = parseInstant(
                    metadata["published"].stringOrNull()
                        ?: metadata["modified"].stringOrNull()
                        ?: metadata["updated"].stringOrNull(),
                ),
                libraryId = "root",
                hasAudio = hasMedia(acquisitions, AppMediaType.AUDIOBOOK),
                hasEbook = hasMedia(acquisitions, AppMediaType.EBOOK),
                publishedDate = metadata["published"].stringOrNull(),
                narrator = jsonAuthors(metadata["narrator"]).joinToString(", ").takeIf { it.isNotBlank() },
                publisher = jsonAuthors(metadata["publisher"]).firstOrNull(),
                categories = jsonAuthors(metadata["subject"]),
                language = jsonFirstString(metadata["language"]),
                isbn13 = isbn13Of(identifier),
                pageCount = metadata["numberOfPages"].intOrNull(),
                durationSeconds = metadata["duration"].secondsOrNull(),
                opdsAcquisitionUrl = selected?.downloadHref,
                opdsProgressionUrl = progressionUrl,
            ),
            acquisitions = acquisitions,
            selectedAcquisition = selected,
            progressionUrl = progressionUrl,
            progressionAuthenticateUrl = progressionLink?.let { jsonAuthenticateUrl(it, baseUrl) },
        )
    }

    private fun jsonAuthenticateUrl(link: JsonObject, baseUrl: String): String? {
        val authenticate = (link["properties"] as? JsonObject)?.get("authenticate") ?: return null
        val href = (authenticate as? JsonObject)?.get("href").stringOrNull()
            ?: authenticate.stringOrNull()
            ?: return null
        return httpResolve(baseUrl, href)
    }

    private fun jsonAcquisition(link: JsonObject, baseUrl: String): OpdsAcquisition? {
        val mediaType = link["type"].stringOrNull().orEmpty()
        val kind = acquisitionKindFor(jsonLinkRel(link), mediaType) ?: return null
        val href = httpResolve(baseUrl, link["href"].stringOrNull()) ?: return null
        val properties = link["properties"] as? JsonObject
        return buildAcquisition(
            kind = kind,
            href = href,
            mediaType = mediaType,
            title = link["title"].stringOrNull(),
            indirect = jsonIndirect(properties?.get("indirectAcquisition")),
            price = (properties?.get("price") as? JsonObject)?.let {
                val value = it["value"].stringOrNull()?.toDoubleOrNull() ?: return@let null
                OpdsPrice(currency = it["currency"].stringOrNull(), value = value)
            },
            availability = (properties?.get("availability") as? JsonObject)?.let {
                OpdsAvailability(
                    state = it["state"].stringOrNull(),
                    since = it["since"].stringOrNull(),
                    until = it["until"].stringOrNull(),
                )
            },
            copies = (properties?.get("copies") as? JsonObject)?.let {
                OpdsCopies(total = it["total"].intOrNull(), available = it["available"].intOrNull())
            },
            holds = (properties?.get("holds") as? JsonObject)?.let {
                OpdsHolds(total = it["total"].intOrNull(), position = it["position"].intOrNull())
            },
            lcpHint = properties?.containsKey("lcp_hashed_passphrase") == true,
        )
    }

    private fun jsonIndirect(element: JsonElement?): List<OpdsIndirectAcquisition> =
        element.objects().mapNotNull { node ->
            val type = node["type"].stringOrNull() ?: return@mapNotNull null
            OpdsIndirectAcquisition(type, jsonIndirect(node["child"] ?: node["children"]))
        }

    private fun parseJsonNavigation(link: JsonObject, baseUrl: String): NavigationLink? {
        val href = httpResolve(baseUrl, link["href"].stringOrNull()) ?: return null
        return NavigationLink(
            title = localizedString(link["title"]).orEmpty(),
            href = href,
            rel = jsonLinkRel(link).joinToString(" "),
            type = link["type"].stringOrNull().orEmpty(),
            numberOfItems = (link["properties"] as? JsonObject)?.get("numberOfItems").intOrNull(),
        )
    }

    private fun parseJsonCatalog(catalog: JsonObject, baseUrl: String): NavigationLink? {
        if (catalog.containsKey("href")) return parseJsonNavigation(catalog, baseUrl)
        val links = catalog["links"].objects()
        val link = links.firstOrNull { jsonLinkRel(it).any { rel -> rel == "${OPDS_PREFIX}catalog" } }
            ?: links.firstOrNull { jsonLinkRel(it).any { rel -> rel.equals("self", ignoreCase = true) } }
            ?: links.firstOrNull()
            ?: return null
        val href = httpResolve(baseUrl, link["href"].stringOrNull()) ?: return null
        val metadata = catalog["metadata"] as? JsonObject
        return NavigationLink(
            title = localizedString(metadata?.get("title")) ?: localizedString(link["title"]).orEmpty(),
            href = href,
            rel = jsonLinkRel(link).joinToString(" "),
            type = link["type"].stringOrNull().orEmpty(),
            numberOfItems = metadata?.get("numberOfItems").intOrNull(),
        )
    }

    private fun parseJsonFacetGroup(group: JsonObject, baseUrl: String): List<OpdsFacet> {
        val groupTitle = localizedString((group["metadata"] as? JsonObject)?.get("title")).orEmpty()
        return group["links"].objects().mapNotNull { link ->
            val href = httpResolve(baseUrl, link["href"].stringOrNull()) ?: return@mapNotNull null
            val properties = link["properties"] as? JsonObject
            OpdsFacet(
                groupTitle = groupTitle,
                title = localizedString(link["title"]).orEmpty(),
                href = href,
                type = link["type"].stringOrNull().orEmpty(),
                numberOfItems = properties?.get("numberOfItems").intOrNull(),
                isActive = jsonLinkRel(link).any { it.equals("self", ignoreCase = true) },
            )
        }
    }

    private fun parseJsonSearchLink(link: JsonObject, baseUrl: String): OpdsSearchLink? {
        if (!jsonLinkRel(link).any { it.equals("search", ignoreCase = true) }) return null
        val raw = link["href"].stringOrNull() ?: return null
        val href = httpResolve(baseUrl, raw) ?: return null
        return OpdsSearchLink(
            href = href,
            type = link["type"].stringOrNull().orEmpty(),
            title = localizedString(link["title"]),
            templated = link["templated"].stringOrNull()?.equals("true", ignoreCase = true) == true || raw.contains('{'),
        )
    }

    private fun jsonCoverUrl(publication: JsonObject, links: List<JsonObject>, baseUrl: String): String? {
        val images = publication["images"].objects()
        val candidate = images.firstOrNull { isJsonThumbnail(it) }
            ?: images.minByOrNull { it["width"].intOrNull() ?: Int.MAX_VALUE }
            ?: links.firstOrNull { isJsonThumbnail(it) }
            ?: links.firstOrNull { isJsonCover(it) }
        return httpResolve(baseUrl, candidate?.get("href").stringOrNull())
    }

    private fun buildAcquisition(
        kind: OpdsAcquisitionKind,
        href: String,
        mediaType: String,
        title: String?,
        indirect: List<OpdsIndirectAcquisition>,
        price: OpdsPrice?,
        availability: OpdsAvailability?,
        copies: OpdsCopies?,
        holds: OpdsHolds?,
        lcpHint: Boolean = false,
    ): OpdsAcquisition {
        val linkFormat = formatFor(mediaType)
        val chainTypes = flattenIndirect(indirect)
        val terminalFormat = chainTypes.map { formatFor(it) }.lastOrNull { it != OpdsFormat.UNKNOWN }
        val requiresIndirectFetch = !linkFormat.isReadableContent && chainTypes.isNotEmpty()
        val drm = when {
            lcpHint -> OpdsDrm.LCP
            (chainTypes + mediaType).any { isLcpType(it) } -> OpdsDrm.LCP
            (chainTypes + mediaType).any { it.substringBefore(';').trim().equals(ADEPT_TYPE, ignoreCase = true) } -> OpdsDrm.ADEPT
            else -> OpdsDrm.NONE
        }
        val extensionFormat = formatForExtension(href)
        val hintFormat = formatForHint(title)
        val format = when {
            linkFormat.isReadableContent -> linkFormat
            terminalFormat != null && terminalFormat.isReadableContent -> terminalFormat
            extensionFormat != OpdsFormat.UNKNOWN -> extensionFormat
            hintFormat != OpdsFormat.UNKNOWN -> hintFormat
            terminalFormat != null -> terminalFormat
            else -> linkFormat
        }
        return OpdsAcquisition(
            kind = kind,
            href = href,
            mediaType = mediaType,
            format = format,
            drm = drm,
            title = title,
            requiresIndirectFetch = requiresIndirectFetch,
            indirect = indirect,
            price = price,
            availability = availability,
            copies = copies,
            holds = holds,
        )
    }

    private fun flattenIndirect(indirect: List<OpdsIndirectAcquisition>): List<String> =
        indirect.flatMap { listOf(it.type) + flattenIndirect(it.children) }

    private fun isLcpType(mediaType: String): Boolean {
        val type = mediaType.substringBefore(';').trim().lowercase()
        return type.contains("lcp.license") || type.endsWith("+lcp")
    }

    fun acquisitionKind(rels: List<String>): OpdsAcquisitionKind? {
        val kinds = rels.mapNotNull { kindForRel(it) }
        if (kinds.isEmpty()) return null
        return kinds.filter { it != OpdsAcquisitionKind.GENERIC }.minByOrNull { it.ordinal }
            ?: OpdsAcquisitionKind.GENERIC
    }

    private fun acquisitionKindFor(rels: List<String>, mediaType: String): OpdsAcquisitionKind? =
        acquisitionKind(rels) ?: OpdsAcquisitionKind.GENERIC.takeIf { formatFor(mediaType).isReadableContent }

    private fun kindForRel(rel: String): OpdsAcquisitionKind? {
        val normalized = rel.trim().lowercase()
            .removePrefix(OPDS_PREFIX)
            .removePrefix("https://opds-spec.org/")
            .removePrefix("acquisition/")
        return when (normalized) {
            "acquisition", "download" -> OpdsAcquisitionKind.GENERIC
            "open-access", "openaccess" -> OpdsAcquisitionKind.OPEN_ACCESS
            "borrow", "borrowing" -> OpdsAcquisitionKind.BORROW
            "buy", "buying", "purchase" -> OpdsAcquisitionKind.BUY
            "sample", "preview" -> OpdsAcquisitionKind.PREVIEW
            "subscribe", "subscription" -> OpdsAcquisitionKind.SUBSCRIBE
            else -> null
        }
    }

    fun isTraversableFeedType(type: String): Boolean {
        val normalized = type.trim().lowercase()
        if (normalized.isEmpty()) return true
        if (normalized.contains("opds-publication+json")) return false
        return normalized.startsWith("application/atom+xml") ||
            normalized.startsWith("application/opds+json") ||
            normalized.contains("profile=opds-catalog")
    }

    fun isWebCatalogType(type: String): Boolean =
        when (type.substringBefore(';').trim().lowercase()) {
            "text/html", "application/xhtml+xml" -> true
            else -> false
        }

    private fun listedSummaries(publications: List<OpdsPublication>): List<BookSummary> =
        publications.map { it.summary }.distinctBy { it.id }

    private fun hasMedia(acquisitions: List<OpdsAcquisition>, mediaType: AppMediaType): Boolean =
        acquisitions.any { mediaTypeFor(it) == mediaType }

    private fun isNavigationLink(rel: String, type: String): Boolean {
        val normalizedRel = rel.lowercase()
        val normalizedType = type.lowercase()
        return normalizedRel.contains("subsection") ||
            normalizedRel.contains("collection") ||
            normalizedRel.contains("catalog") ||
            normalizedType.contains("profile=opds-catalog") ||
            normalizedType.contains("kind=navigation")
    }

    private fun isProgressionLink(rels: List<String>, type: String?): Boolean {
        if (rels.none { it.trim().equals(OPDS_PROGRESSION_REL, ignoreCase = true) }) return false
        return type?.substringBefore(';')?.trim()?.equals(OPDS_PROGRESSION_MEDIA_TYPE, ignoreCase = true) == true
    }

    private fun isCoverRel(rel: String): Boolean {
        val normalized = rel.lowercase()
        return normalized.endsWith("/image") ||
            normalized.contains("opds-spec.org/image") ||
            normalized.endsWith("/cover") ||
            normalized == "cover"
    }

    private fun isThumbnailRel(rel: String): Boolean = rel.contains("thumbnail", ignoreCase = true)

    private fun isJsonCover(link: JsonObject): Boolean {
        val rel = jsonLinkRel(link).joinToString(" ").lowercase()
        val type = link["type"].stringOrNull().orEmpty().lowercase()
        return rel.endsWith("/image") || rel.contains("cover") || type.startsWith("image/")
    }

    private fun isJsonThumbnail(link: JsonObject): Boolean =
        jsonLinkRel(link).any { it.contains("thumbnail", ignoreCase = true) }

    fun formatFor(mimeType: String): OpdsFormat {
        val full = mimeType.trim().lowercase()
        val base = full.substringBefore(';').trim()
        return when {
            base.isEmpty() -> OpdsFormat.UNKNOWN
            base.startsWith("application/epub") -> OpdsFormat.EPUB
            base == "application/pdf" || base == "application/pdf+lcp" -> OpdsFormat.PDF
            base.contains("cbz") || (base.contains("comicbook") && base.contains("zip")) -> OpdsFormat.CBZ
            base.contains("cbr") || (base.contains("comicbook") && base.contains("rar")) -> OpdsFormat.CBR
            base.contains("comicbook") -> OpdsFormat.CBZ
            base == "application/x-mobipocket-ebook" -> OpdsFormat.MOBI
            base == "application/vnd.amazon.mobi8-ebook" || base == "application/vnd.amazon.ebook" -> OpdsFormat.AZW3
            base.startsWith("application/audiobook") -> OpdsFormat.AUDIOBOOK_PACKAGE
            base.startsWith("audio/") -> OpdsFormat.AUDIO
            base.startsWith("application/divina") -> OpdsFormat.DIVINA
            base.startsWith("application/webpub") -> OpdsFormat.WEBPUB
            base == "application/opds-publication+json" -> OpdsFormat.OPDS_PUBLICATION
            base.startsWith("application/atom+xml") ||
                base.startsWith("application/opds+json") ||
                full.contains("profile=opds-catalog") -> OpdsFormat.OPDS_FEED

            else -> OpdsFormat.UNKNOWN
        }
    }

    private fun formatForExtension(url: String?): OpdsFormat = formatForToken(fileExtension(url))

    private fun formatForHint(hint: String?): OpdsFormat = formatForToken(hint?.trim()?.lowercase())

    private fun formatForToken(token: String?): OpdsFormat = when (token) {
        null -> OpdsFormat.UNKNOWN
        "epub" -> OpdsFormat.EPUB
        "pdf" -> OpdsFormat.PDF
        "cbz" -> OpdsFormat.CBZ
        "cbr" -> OpdsFormat.CBR
        "mobi", "prc" -> OpdsFormat.MOBI
        "azw", "azw3" -> OpdsFormat.AZW3
        else -> if (audioExtensions.contains(token)) OpdsFormat.AUDIO else OpdsFormat.UNKNOWN
    }

    private fun mediaTypeFor(acquisition: OpdsAcquisition): AppMediaType =
        inferMediaType(acquisition.mediaType, acquisition.href, acquisition.title)

    private fun fileTypeFor(acquisition: OpdsAcquisition): String? {
        acquisition.title?.trim()?.uppercase()?.let { if (it in knownFormatHints) return it }
        return when (acquisition.format) {
            OpdsFormat.EPUB -> "EPUB"
            OpdsFormat.PDF -> "PDF"
            OpdsFormat.CBZ -> "CBZ"
            OpdsFormat.CBR -> "CBR"
            OpdsFormat.MOBI -> "MOBI"
            OpdsFormat.AZW3 -> "AZW3"
            OpdsFormat.AUDIO, OpdsFormat.AUDIOBOOK_PACKAGE -> "AUDIOBOOK"
            OpdsFormat.DIVINA -> "DIVINA"
            OpdsFormat.WEBPUB -> "WEBPUB"
            else -> inferFileType(acquisition.mediaType, acquisition.href, acquisition.title)
        }
    }

    fun inferMediaType(mimeType: String, url: String?, titleHint: String? = null): AppMediaType {
        val hint = titleHint.orEmpty().trim().lowercase()
        if (mimeType.startsWith("audio/") || mimeType.contains("audiobook") || audioExtensions.any { hint == it }) {
            return AppMediaType.AUDIOBOOK
        }
        val extension = fileExtension(url) ?: return AppMediaType.EBOOK
        return if (audioExtensions.contains(extension)) AppMediaType.AUDIOBOOK else AppMediaType.EBOOK
    }

    fun inferFileType(mimeType: String, url: String?, titleHint: String? = null): String? {
        titleHint?.trim()?.uppercase()?.let { hint ->
            if (hint in knownFormatHints) return hint
        }
        val format = formatFor(mimeType).takeIf { it != OpdsFormat.UNKNOWN } ?: formatForExtension(url)
        return when (format) {
            OpdsFormat.EPUB -> "EPUB"
            OpdsFormat.PDF -> "PDF"
            OpdsFormat.CBZ -> "CBZ"
            OpdsFormat.CBR -> "CBR"
            OpdsFormat.MOBI -> "MOBI"
            OpdsFormat.AZW3 -> "AZW3"
            OpdsFormat.AUDIO, OpdsFormat.AUDIOBOOK_PACKAGE -> "AUDIOBOOK"
            OpdsFormat.DIVINA -> "DIVINA"
            OpdsFormat.WEBPUB -> "WEBPUB"
            else -> null
        }
    }

    fun parseInstant(raw: String?): Long {
        val text = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return 0L
        return runCatching { OffsetDateTime.parse(text).toInstant().toEpochMilli() }
            .recoverCatching { LocalDate.parse(text).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli() }
            .getOrDefault(0L)
    }

    private fun isbn13Of(identifier: String?): String? {
        val raw = identifier?.trim()?.lowercase(Locale.ROOT) ?: return null
        if (!raw.startsWith("urn:isbn:") && !raw.startsWith("isbn:")) return null
        return raw.substringAfterLast(':').filter(Char::isDigit).takeIf { it.length == 13 }
    }

    fun resolve(baseUrl: String, href: String): String {
        if (href.isBlank()) return baseUrl
        if (href.startsWith("//")) return "${baseUrl.substringBefore("//", "https:")}$href"
        if (schemeRegex.containsMatchIn(href)) return href
        return runCatching { URI(baseUrl).resolve(href).toString() }
            .getOrElse { resolveManually(baseUrl, href) }
    }

    private fun httpResolve(baseUrl: String, href: String?): String? {
        val raw = href?.takeIf { it.isNotBlank() } ?: return null
        return resolve(baseUrl, raw).takeIf(::isHttpUrl)
    }

    private fun resolveManually(baseUrl: String, href: String): String {
        val schemeEnd = baseUrl.indexOf("://")
        val authorityEnd = if (schemeEnd < 0) -1 else baseUrl.indexOf('/', schemeEnd + 3)
        val origin = if (authorityEnd < 0) baseUrl.trimEnd('/') else baseUrl.substring(0, authorityEnd)
        if (href.startsWith("/")) return "$origin$href"
        val path = baseUrl.substringBefore('?').substringBefore('#')
        return "${path.substringBeforeLast('/', origin)}/$href"
    }

    private fun fileExtension(url: String?): String? {
        val path = url?.substringBefore('?')?.substringBefore('#') ?: return null
        return path.substringAfterLast('/').substringAfterLast('.', "").lowercase().takeIf { it.isNotBlank() }
    }

    private fun relTokens(rel: String?): List<String> =
        rel.orEmpty().split(' ', '\t', '\n').mapNotNull { it.trim().lowercase().takeIf(String::isNotEmpty) }

    private fun Element.isNamed(name: String): Boolean =
        tagName().substringAfterLast(':').equals(name, ignoreCase = true)

    private fun Element.childrenNamed(name: String): List<Element> = children().filter { it.isNamed(name) }

    private fun Element.childNamed(name: String): Element? = children().firstOrNull { it.isNamed(name) }

    private fun Element.textOf(name: String): String? =
        childNamed(name)?.text()?.trim()?.takeIf { it.isNotEmpty() }

    private fun Element.attrAny(name: String): String? = attributes()
        .firstOrNull { it.key.substringAfterLast(':').equals(name, ignoreCase = true) }
        ?.value
        ?.takeIf { it.isNotBlank() }

    private fun JsonElement?.intOrNull(): Int? = stringOrNull()?.trim()?.toDoubleOrNull()?.toInt()

    private fun JsonElement?.secondsOrNull(): Long =
        stringOrNull()?.trim()?.toDoubleOrNull()?.takeIf { it > 0.0 }?.roundToLong() ?: 0L

    private fun jsonLinkRel(link: JsonObject): List<String> {
        val rel = link["rel"]
        return when (rel) {
            is JsonArray -> rel.mapNotNull { it.stringOrNull() }
            else -> listOfNotNull(rel.stringOrNull())
        }
    }

    private fun localizedString(element: JsonElement?): String? = when (element) {
        is JsonObject -> element.preferredTranslation()
        is JsonArray -> element.firstNotNullOfOrNull { localizedString(it) }
        else -> element.stringOrNull()
    }?.takeIf { it.isNotBlank() }

    private fun JsonObject.preferredTranslation(): String? {
        val locale = Locale.getDefault()
        val key = keys.firstOrNull { it.equals(locale.toLanguageTag(), ignoreCase = true) }
            ?: keys.firstOrNull { it.substringBefore('-').equals(locale.language, ignoreCase = true) }
            ?: keys.firstOrNull { it.substringBefore('-').equals("en", ignoreCase = true) }
            ?: keys.firstOrNull()
            ?: return null
        return this[key].stringOrNull()
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
            is JsonObject -> localizedString(element["name"])
            else -> element.stringOrNull()
        }?.takeIf { it.isNotBlank() }
    }

    private fun jsonFirstString(element: JsonElement?): String? = when (element) {
        is JsonArray -> element.firstNotNullOfOrNull { it.stringOrNull() }
        else -> element.stringOrNull()
    }?.takeIf { it.isNotBlank() }

    private fun jsonSeries(element: JsonElement?): Pair<String, String?>? {
        val series = (element as? JsonObject)?.get("series") ?: element ?: return null
        val node = when (series) {
            is JsonArray -> series.firstOrNull()
            else -> series
        } ?: return null
        return when (node) {
            is JsonObject -> localizedString(node["name"])
                ?.let { it to node["position"].stringOrNull() }

            else -> node.stringOrNull()?.takeIf { it.isNotBlank() }?.let { it to null }
        }
    }

    private val audioExtensions = setOf("mp3", "m4a", "m4b", "flac", "ogg", "opus", "wav", "aac", "aax")
    private val knownFormatHints = setOf(
        "EPUB", "PDF", "CBZ", "CBR", "MOBI", "AZW3",
        "MP3", "M4A", "M4B", "FLAC", "OGG", "OPUS", "WAV", "AAC", "AAX",
    )
}
