package com.enve.app.data.sync

import com.enve.core.data.util.stringLiteralOrNull
import com.enve.core.reader.EpubBridgeCheckpointCodec
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import org.jsoup.nodes.TextNode
import org.jsoup.parser.Parser
import java.io.File
import java.util.zip.ZipFile

object KOReaderHubXPointerConverter {

    fun locatorJson(xpointer: String, percentage: Double, epubFile: File): String? =
        runCatching { convert(xpointer, percentage, epubFile) }.getOrNull()

    fun xpointer(locatorJson: String, epubFile: File): String? =
        runCatching { reverseConvert(locatorJson, epubFile) }.getOrNull()

    private data class PathSegment(val tagName: String, val index: Int)

    private data class ParsedXPointer(
        val spineIndex: Int,
        val elementPath: List<PathSegment>,
        val textNodeIndex: Int?,
        val textOffset: Int?,
    )

    private data class ChunkPoint(val step: Int, val offset: Int)

    private data class TextPoint(val textNodeIndex: Int, val codePointOffset: Int)

    private data class ResolvedCfi(val path: List<PathSegment>, val text: TextPoint?)

    private val XPOINTER_PREFIX = Regex("""^/body/DocFragment\[(\d+)]/body""")
    private val TEXT_TAIL = Regex("""/text\(\)(?:\[(\d+)])?(?:\.(\d+))?$""")
    private val OFFSET_TAIL = Regex("""\.(\d+)$""")
    private val PATH_SEGMENT = Regex("""^([A-Za-z_][\w\-:]*)(?:\[(\d+)])?$""")
    private val CFI_ASSERTION = Regex("""\[[^\]]*]""")
    private val CFI_CHAR_OFFSET = Regex(""":(\d+)$""")

    private fun convert(xpointer: String, percentage: Double, epubFile: File): String {
        val parsed = parseXPointer(xpointer) ?: error("invalid xpointer")
        val spineHrefs = readSpineHrefs(epubFile)
        require(parsed.spineIndex in spineHrefs.indices) { "spine index out of bounds" }

        val spineHref = spineHrefs[parsed.spineIndex]
        val dom = HtmlDom(readDocument(epubFile, spineHref) ?: error("spine item unreadable"))
        val target = dom.resolve(parsed.elementPath) ?: error("element not found")

        val partialCfi = StringBuilder(dom.cfiSteps(target))
        val offset = parsed.textOffset
        if (offset != null) {
            val chunk = dom.chunkPoint(target, parsed.textNodeIndex, offset)
            if (chunk == null && parsed.textNodeIndex != null) error("text node not found")
            chunk?.let { partialCfi.append("/${it.step}:${it.offset}") }
        }
        return buildLocatorJson(spineHref, partialCfi.toString(), parsed.spineIndex, percentage)
    }

    private fun reverseConvert(locatorJson: String, epubFile: File): String {
        val root = Json.parseToJsonElement(locatorJson) as? JsonObject ?: error("invalid locator")
        val href = EpubBridgeCheckpointCodec.href(locatorJson) ?: error("missing href")
        val partialCfi = contentCfi(locatorJson, root) ?: error("no CFI")

        val spineHrefs = readSpineHrefs(epubFile)
        val spineIndex = spineHrefs.indexOfFirst { it == href || it.endsWith("/$href") }
        require(spineIndex >= 0) { "href not in spine" }

        val dom = HtmlDom(readDocument(epubFile, spineHrefs[spineIndex]) ?: error("spine item unreadable"))
        val resolved = resolveCfi(dom, partialCfi)

        return buildString {
            append("/body/DocFragment[${spineIndex + 1}]/body")
            for (segment in resolved.path) append("/${segment.tagName}[${segment.index}]")
            val text = resolved.text
            if (text != null) append("/text()[${text.textNodeIndex}].${text.codePointOffset}")
            else append(".0")
        }
    }

    private fun parseXPointer(xpointer: String): ParsedXPointer? {
        val trimmed = xpointer.trim()
        val prefix = XPOINTER_PREFIX.find(trimmed) ?: return null
        val spineIndex = (prefix.groupValues[1].toIntOrNull() ?: return null) - 1
        if (spineIndex < 0) return null

        var rest = trimmed.substring(prefix.value.length)
        var textNodeIndex: Int? = null
        var textOffset: Int? = null

        val textTail = TEXT_TAIL.find(rest)
        if (textTail != null) {
            textNodeIndex = textTail.groupValues[1].toIntOrNull() ?: 1
            textOffset = textTail.groupValues[2].toIntOrNull() ?: 0
            rest = rest.substring(0, textTail.range.first)
        } else {
            OFFSET_TAIL.find(rest)?.let { offsetTail ->
                textOffset = offsetTail.groupValues[1].toIntOrNull()
                rest = rest.substring(0, offsetTail.range.first)
            }
        }

        val path = parseElementPath(rest) ?: return null
        return ParsedXPointer(spineIndex, path, textNodeIndex, textOffset)
    }

    private fun parseElementPath(path: String): List<PathSegment>? {
        if (path.isBlank()) return emptyList()
        return path.split('/').filter { it.isNotBlank() }.map { raw ->
            val match = PATH_SEGMENT.find(raw) ?: return null
            PathSegment(
                match.groupValues[1].substringAfterLast(':').lowercase(),
                match.groupValues[2].toIntOrNull() ?: 1,
            )
        }
    }

    private fun resolveCfi(dom: HtmlDom, partialCfi: String): ResolvedCfi {
        var cfi = partialCfi.trim().replace(CFI_ASSERTION, "")
        require(!cfi.contains(',')) { "range CFIs do not name a single position" }

        var charOffset: Int? = null
        CFI_CHAR_OFFSET.find(cfi)?.let { match ->
            charOffset = match.groupValues[1].toInt()
            cfi = cfi.substring(0, match.range.first)
        }

        val steps = cfi.split('/').filter { it.isNotBlank() }
            .map { it.toIntOrNull() ?: error("unsupported CFI step '$it'") }
        require(steps.isNotEmpty()) { "empty CFI" }

        var current = dom.root
        val path = mutableListOf<PathSegment>()
        for ((index, step) in steps.withIndex()) {
            if (step % 2 == 1) {
                require(index == steps.lastIndex) { "character data step is not final" }
                val text = dom.textPoint(current, step, charOffset ?: 0)
                    ?: error("CFI step $step has no character data")
                return ResolvedCfi(path, text)
            }
            val child = dom.elementChild(current, step / 2) ?: error("CFI step $step does not resolve")
            if (index == 0) require(child === dom.body) { "CFI is not rooted at <body>" }
            else path += PathSegment(localName(child), dom.tagIndex(child))
            current = child
        }
        require(charOffset == null) { "character offset on an element step" }
        return ResolvedCfi(path, null)
    }

    private fun buildLocatorJson(
        href: String,
        partialCfi: String,
        spineIndex: Int,
        progression: Double,
    ): String = buildJsonObject {
        put("href", JsonPrimitive(href))
        put("type", JsonPrimitive("application/xhtml+xml"))
        put("locations", buildJsonObject {
            put("totalProgression", JsonPrimitive(progression.coerceIn(0.0, 1.0)))
            put("partialCfi", JsonPrimitive(partialCfi))
            put("cfi", JsonPrimitive("epubcfi(/6/${(spineIndex + 1) * 2}!$partialCfi)"))
        })
    }.toString()

    private fun contentCfi(locatorJson: String, root: JsonObject): String? {
        (root["locations"] as? JsonObject)?.get("partialCfi").stringLiteralOrNull()?.takeIf { it.isNotBlank() }?.let { return it.contentPath() }
        return EpubBridgeCheckpointCodec.cfi(locatorJson)?.contentPath()
    }

    private fun String.contentPath(): String? =
        removePrefix("epubcfi(").removeSuffix(")").substringAfterLast('!').trim().ifBlank { null }

    private fun readSpineHrefs(epubFile: File): List<String> = ZipFile(epubFile).use { zip ->
        val container = zip.readDocument("META-INF/container.xml") ?: error("no container.xml")
        val opfPath = container.withLocalName("rootfile")
            .firstNotNullOfOrNull { it.attr("full-path").takeIf(String::isNotBlank) }
            ?: error("no OPF path")
        val opf = zip.readDocument(opfPath) ?: error("OPF missing")
        val opfBaseDir = opfPath.substringBeforeLast('/', "")

        val hrefById = opf.withLocalName("item").mapNotNull { item ->
            val id = item.attr("id").takeIf(String::isNotBlank) ?: return@mapNotNull null
            val href = item.attr("href").takeIf(String::isNotBlank) ?: return@mapNotNull null
            id to href
        }.toMap()

        opf.withLocalName("itemref")
            .filter { it.attr("linear") != "no" }
            .mapNotNull { hrefById[it.attr("idref")] }
            .map { if (opfBaseDir.isEmpty()) it else "$opfBaseDir/$it" }
    }

    private fun readDocument(epubFile: File, entryPath: String): Document? =
        ZipFile(epubFile).use { it.readDocument(entryPath) }

    private fun ZipFile.readDocument(entryPath: String): Document? {
        val entry = getEntry(entryPath) ?: return null
        return getInputStream(entry).use { Jsoup.parse(it, null, "", Parser.xmlParser()) }
    }

    private fun Document.withLocalName(name: String): List<Element> =
        allElements.filter { localName(it) == name }

    private class HtmlDom(document: Document) {
        val root: Element = document.children().firstOrNull() ?: document
        val body: Element = root.allElements.firstOrNull { localName(it) == "body" } ?: root

        fun resolve(path: List<PathSegment>): Element? {
            var current = body
            for (segment in path) {
                current = current.children()
                    .filter { localName(it) == segment.tagName }
                    .getOrNull(segment.index - 1)
                    ?: return null
            }
            return current
        }

        fun elementChild(parent: Element, position: Int): Element? =
            parent.children().getOrNull(position - 1)

        fun tagIndex(node: Element): Int {
            val parent = node.parent() ?: return 1
            val name = localName(node)
            var index = 0
            for (child in parent.children()) {
                if (localName(child) == name) index++
                if (child === node) return index
            }
            return 1
        }

        fun cfiSteps(node: Element): String {
            val steps = ArrayList<String>()
            var current: Element = node
            while (current !== root) {
                val parent = current.parent() ?: break
                steps.add(0, "/${(current.elementSiblingIndex() + 1) * 2}")
                current = parent
            }
            return steps.joinToString("")
        }

        fun chunkPoint(element: Element, textNodeIndex: Int?, codePointOffset: Int): ChunkPoint? {
            val target = element.childNodes()
                .filterIsInstance<TextNode>()
                .getOrNull((textNodeIndex ?: 1) - 1)
                ?: return null
            var elementsBefore = 0
            var chunkLength = 0
            for (node in element.childNodes()) {
                if (node === target) {
                    return ChunkPoint(
                        step = 2 * elementsBefore + 1,
                        offset = chunkLength + utf16Offset(target.wholeText, codePointOffset),
                    )
                }
                if (node is Element) {
                    elementsBefore++
                    chunkLength = 0
                } else if (node is TextNode) {
                    chunkLength += node.wholeText.length
                }
            }
            return null
        }

        fun textPoint(element: Element, step: Int, utf16Offset: Int): TextPoint? {
            val elementsBefore = (step - 1) / 2
            var seenElements = 0
            var textNodeIndex = 0
            val chunk = mutableListOf<Pair<Int, String>>()
            for (node in element.childNodes()) {
                if (node is Element) {
                    if (seenElements == elementsBefore) break
                    seenElements++
                } else if (node is TextNode) {
                    textNodeIndex++
                    if (seenElements == elementsBefore) chunk += textNodeIndex to node.wholeText
                }
            }
            if (chunk.isEmpty()) return null

            var remaining = utf16Offset.coerceAtLeast(0)
            for ((index, text) in chunk) {
                if (remaining < text.length) return TextPoint(index, codePointOffset(text, remaining))
                remaining -= text.length
            }
            val (index, text) = chunk.last()
            return TextPoint(index, codePointOffset(text, text.length))
        }
    }
}

private fun localName(element: Element): String =
    element.tagName().substringAfterLast(':').lowercase()

private fun utf16Offset(text: String, codePointOffset: Int): Int = when {
    codePointOffset <= 0 -> 0
    codePointOffset >= text.codePointCount(0, text.length) -> text.length
    else -> text.offsetByCodePoints(0, codePointOffset)
}

private fun codePointOffset(text: String, utf16Offset: Int): Int {
    val clamped = utf16Offset.coerceIn(0, text.length)
    val boundary = if (clamped in 1 until text.length && Character.isLowSurrogate(text[clamped])) {
        clamped - 1
    } else {
        clamped
    }
    return text.codePointCount(0, boundary)
}
