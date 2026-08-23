package com.enve.app.data.sync

import android.util.Xml
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.util.zip.ZipFile

object KOReaderHubXPointerConverter {

    fun locatorJson(xpointer: String, percentage: Double, epubFile: File): String? =
        runCatching { convert(xpointer, percentage, epubFile) }.getOrNull()

    fun xpointer(locatorJson: String, epubFile: File): String? =
        runCatching { reverseConvert(locatorJson, epubFile) }.getOrNull()

    private data class ParsedXPointer(
        val spineIndex: Int,
        val elementPath: List<PathSegment>,
        val textOffset: Int?,
    )

    private data class PathSegment(val tagName: String, val index: Int)

    private fun convert(xpointer: String, percentage: Double, epubFile: File): String {
        val parsed = parseXPointer(xpointer) ?: error("invalid xpointer")
        val spineHrefs = readSpineHrefs(epubFile)
        require(parsed.spineIndex in spineHrefs.indices) { "spine index out of bounds" }

        val spineHref = spineHrefs[parsed.spineIndex]
        val html = readEntryText(epubFile, spineHref) ?: error("spine item unreadable")

        val partialCfi = buildPartialCfi(html, parsed.elementPath, parsed.textOffset)
        return buildLocatorJson(spineHref, partialCfi, percentage)
    }

    private fun parseXPointer(xpointer: String): ParsedXPointer? {
        val re = Regex("""^/body/DocFragment\[(\d+)]/body(.*?)(?:/text\(\)\.(\d+))?$""")
        val m = re.find(xpointer.trim()) ?: return null
        val spineN = m.groupValues[1].toIntOrNull() ?: return null
        val bodyPath = m.groupValues[2]
        val textOffset = m.groupValues[3].toIntOrNull()
        return ParsedXPointer(spineN - 1, parseElementPath(bodyPath), textOffset)
    }

    private fun parseElementPath(path: String): List<PathSegment> {
        if (path.isBlank()) return emptyList()
        return path.split("/").filter { it.isNotBlank() }.map { seg ->
            val indexed = Regex("""^(\w+)\[(\d+)]$""").find(seg)
            if (indexed != null) {
                PathSegment(indexed.groupValues[1].lowercase(), indexed.groupValues[2].toInt())
            } else {
                PathSegment(seg.lowercase(), 1)
            }
        }
    }

    private fun buildPartialCfi(
        html: String,
        elementPath: List<PathSegment>,
        textOffset: Int?,
    ): String {
        if (elementPath.isEmpty()) return "/4"
        val dom = HtmlDom(html)
        val target = dom.resolve(elementPath) ?: error("element not found")
        var cfi = "/4" + dom.cfiSteps(target)
        if (textOffset != null) cfi += "/1:$textOffset"
        return cfi
    }

    private fun buildLocatorJson(href: String, partialCfi: String, progression: Double): String {
        val locations = JSONObject()
            .put("totalProgression", progression.coerceIn(0.0, 1.0))
            .put("otherLocations", JSONObject().put("partialCfi", partialCfi))
        return JSONObject()
            .put("href", href)
            .put("type", "application/xhtml+xml")
            .put("locations", locations)
            .toString()
    }

    private fun reverseConvert(locatorJson: String, epubFile: File): String {
        val json = JSONObject(locatorJson)
        val href = json.optString("href").ifBlank { error("missing href") }
        val locations = json.optJSONObject("locations") ?: error("no locations")
        val partialCfi = locations.optJSONObject("otherLocations")?.optString("partialCfi")
            ?.ifBlank { null }
            ?: locations.optJSONArray("fragments")?.takeIf { it.length() > 0 }
                ?.getString(0)?.removePrefix("epubcfi(")?.removeSuffix(")")
            ?: error("no partialCfi")

        val spineHrefs = readSpineHrefs(epubFile)
        val spineIndex = spineHrefs.indexOfFirst { it == href || it.endsWith(href) }
        require(spineIndex >= 0) { "href not in spine" }

        val html = readEntryText(epubFile, spineHrefs[spineIndex]) ?: error("spine item unreadable")
        val (path, textOffset) = buildXPointerPath(html, partialCfi)

        val sb = StringBuilder("/body/DocFragment[${spineIndex + 1}]/body")
        for (seg in path) sb.append("/${seg.tagName}[${seg.index}]")
        if (textOffset != null) sb.append("/text().$textOffset") else sb.append(".0")
        return sb.toString()
    }

    private fun buildXPointerPath(html: String, partialCfi: String): Pair<List<PathSegment>, Int?> {
        val dom = HtmlDom(html)
        var cfi = partialCfi
        if (cfi.startsWith("/4")) cfi = cfi.drop(2)

        var textOffset: Int? = null
        Regex("""(?:/1)?:(\d+)$""").find(cfi)?.let { mt ->
            textOffset = mt.groupValues[1].toIntOrNull()
            cfi = cfi.substring(0, mt.range.first)
        }
        cfi = cfi.replace(Regex("""/text\(\)\[\d+]$"""), "")

        val node = dom.body()
        var current = node
        val out = mutableListOf<PathSegment>()
        for (mt in Regex("""/(\d+)(?:\[([^\]]*)])?""").findAll(cfi)) {
            val step = mt.groupValues[1].toIntOrNull() ?: continue
            if (step % 2 != 0) continue
            val child = dom.elementChild(current, step / 2) ?: break
            out += PathSegment(child.tag, dom.koreaderIndex(child, current))
            current = child
        }
        return out to textOffset
    }

    private fun readSpineHrefs(epubFile: File): List<String> = ZipFile(epubFile).use { zip ->
        val containerEntry = zip.getEntry("META-INF/container.xml") ?: error("no container.xml")
        val opfPath = zip.getInputStream(containerEntry).use { parseOpfPath(it) }
            ?: error("no OPF path")
        val opfEntry = zip.getEntry(opfPath) ?: error("OPF missing")
        val opfBaseDir = opfPath.substringBeforeLast('/', "")
        zip.getInputStream(opfEntry).use { parseSpineHrefs(it, opfBaseDir) }
    }

    private fun parseOpfPath(stream: java.io.InputStream): String? {
        val parser = Xml.newPullParser().apply { setInput(stream, null) }
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            if (event == XmlPullParser.START_TAG && parser.name == "rootfile") {
                return parser.getAttributeValue(null, "full-path")
            }
            event = parser.next()
        }
        return null
    }

    private fun parseSpineHrefs(stream: java.io.InputStream, opfBaseDir: String): List<String> {
        val parser = Xml.newPullParser().apply { setInput(stream, null) }
        val manifestHrefById = HashMap<String, String>()
        val spineIdrefs = ArrayList<String>()
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            if (event == XmlPullParser.START_TAG) {
                when (parser.name.substringAfterLast(':')) {
                    "item" -> {
                        val id = parser.getAttributeValue(null, "id")
                        val href = parser.getAttributeValue(null, "href")
                        if (id != null && href != null) manifestHrefById[id] = href
                    }
                    "itemref" -> {
                        val idref = parser.getAttributeValue(null, "idref")
                        if (idref != null && parser.getAttributeValue(null, "linear") != "no") {
                            spineIdrefs += idref
                        }
                    }
                }
            }
            event = parser.next()
        }
        return spineIdrefs.mapNotNull { idref ->
            manifestHrefById[idref]?.let { href ->
                if (opfBaseDir.isEmpty()) href else "$opfBaseDir/$href"
            }
        }
    }

    private fun readEntryText(epubFile: File, entryPath: String): String? =
        ZipFile(epubFile).use { zip ->
            val entry = zip.getEntry(entryPath) ?: return null
            zip.getInputStream(entry).use { it.readBytes() }
        }.let { bytes ->
            runCatching { String(bytes, Charsets.UTF_8) }.getOrNull()
                ?: runCatching { String(bytes, Charsets.ISO_8859_1) }.getOrNull()
        }

    private class DomNode(val tag: String, val parent: DomNode?) {
        val children = ArrayList<DomNode>()
    }

    private class HtmlDom(html: String) {
        private val root: DomNode
        private val byTag = HashMap<String, MutableList<DomNode>>()

        init {
            val wrapped = if (html.contains("<html") || html.contains("<?xml")) html
            else "<root>$html</root>"
            val parser = Xml.newPullParser().apply {
                setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
                setInput(wrapped.reader())
            }
            var current: DomNode? = null
            var top: DomNode? = null
            var event = parser.eventType
            while (event != XmlPullParser.END_DOCUMENT) {
                when (event) {
                    XmlPullParser.START_TAG -> {
                        val tag = parser.name.lowercase()
                        val node = DomNode(tag, current)
                        current?.children?.add(node)
                        byTag.getOrPut(tag) { ArrayList() }.add(node)
                        if (top == null) top = node
                        current = node
                    }
                    XmlPullParser.END_TAG -> current = current?.parent
                }
                event = runCatching { parser.next() }.getOrElse { XmlPullParser.END_DOCUMENT }
            }
            root = top ?: DomNode("root", null)
        }

        fun body(): DomNode = byTag["body"]?.firstOrNull() ?: root

        fun resolve(path: List<PathSegment>): DomNode? {
            val last = path.lastOrNull() ?: return body()
            return byTag[last.tagName]?.getOrNull(last.index - 1)
        }

        fun elementChild(parent: DomNode, position: Int): DomNode? =
            parent.children.getOrNull(position - 1)

        fun koreaderIndex(node: DomNode, parent: DomNode): Int {
            val sameTag = parent.children.filter { it.tag == node.tag }
            return sameTag.indexOf(node).let { if (it < 0) 0 else it } + 1
        }

        fun cfiSteps(node: DomNode): String {
            val parts = ArrayList<String>()
            var current: DomNode? = node
            while (current != null && current.tag != "body" &&
                current.tag != "html" && current.tag != "root"
            ) {
                val parent = current.parent ?: break
                val pos = parent.children.indexOf(current).let { if (it < 0) 0 else it } + 1
                parts.add(0, "/${pos * 2}")
                current = parent
            }
            return parts.joinToString("")
        }
    }
}
