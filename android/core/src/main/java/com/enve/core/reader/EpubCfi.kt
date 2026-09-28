package com.enve.core.reader

import com.enve.core.data.util.optArray
import com.enve.core.data.util.optDouble
import com.enve.core.data.util.optInt
import com.enve.core.data.util.optObject
import com.enve.core.data.util.optString
import com.enve.core.data.util.stringOrNull
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.StringReader
import java.net.URLDecoder
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.StandardCharsets
import java.util.IdentityHashMap
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import javax.xml.parsers.SAXParserFactory
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.SAXException
import org.xml.sax.ext.DefaultHandler2

object EpubCfi {
    data class Step(
        val index: Int,
        val assertion: String? = null,
        val offset: Int? = null,
    )

    data class Parsed(
        val packagePath: List<Step>,
        val local: List<Step>,
    )

    data class TextPosition(
        val chunk: Int,
        val offset: Int,
    )

    class Point(
        val element: EpubXhtmlDocument.Node,
        val text: TextPosition?,
    ) {
        fun isSameLocation(other: Point): Boolean = element === other.element && text == other.text
    }

    fun parse(value: String): Parsed? {
        val cfi = normalizedEpubCfi(value) ?: return null
        val characters = cfi.substring("epubcfi(".length, cfi.length - 1)
        val paths = mutableListOf(mutableListOf<Step>())
        var commas = 0
        var index = 0

        fun number(): Int? {
            val start = index
            while (index < characters.length && characters[index] in '0'..'9') index++
            return if (index > start) characters.substring(start, index).toIntOrNull() else null
        }

        parsing@ while (index < characters.length) {
            val character = characters[index]
            index++
            when (character) {
                '/' -> paths.last() += Step(number() ?: return null)
                ':' -> {
                    val value = number() ?: return null
                    val path = paths.last()
                    if (path.isEmpty()) return null
                    path[path.lastIndex] = path.last().copy(offset = value)
                }
                '[' -> {
                    val assertion = StringBuilder()
                    var isEscaped = false
                    var hasParameters = false
                    var closed = false
                    while (index < characters.length) {
                        val next = characters[index]
                        index++
                        when {
                            isEscaped -> {
                                if (!hasParameters) assertion.append(next)
                                isEscaped = false
                            }
                            next == '^' -> isEscaped = true
                            next == ']' -> {
                                closed = true
                                break
                            }
                            next == ';' -> hasParameters = true
                            !hasParameters -> assertion.append(next)
                        }
                    }
                    val path = paths.last()
                    val step = path.lastOrNull()
                    if (!closed || step == null) return null
                    if (step.offset == null && step.assertion == null && step.index % 2 == 0 && assertion.isNotEmpty()) {
                        path[path.lastIndex] = step.copy(assertion = assertion.toString())
                    }
                }
                '!' -> paths += mutableListOf<Step>()
                ',' -> {
                    commas++
                    if (commas == 2) break@parsing
                }
                '~', '@' -> while (
                    index < characters.length &&
                    (characters[index].isDigit() || characters[index] == '.' || characters[index] == ':')
                ) {
                    index++
                }
                else -> return null
            }
        }

        if (paths.size != 2 || paths[0].size < 2 || paths[1].isEmpty()) return null
        return Parsed(packagePath = paths[0], local = paths[1])
    }

    fun string(epubPackage: EpubPackage, spineIndex: Int, localPath: String): String {
        val itemref = epubPackage.spine[spineIndex]
        return "epubcfi(/${epubPackage.spineStep}/${(spineIndex + 1) * 2}${assertion(itemref.itemrefId)}!$localPath)"
    }

    fun assertion(id: String?): String {
        if (id.isNullOrEmpty()) return ""
        val escaped = StringBuilder()
        for (character in id) {
            if (character in "^[](),;=") escaped.append('^')
            escaped.append(character)
        }
        return "[$escaped]"
    }

    fun spineIndex(parsed: Parsed, epubPackage: EpubPackage): Int? {
        val itemref = parsed.packagePath.last()
        itemref.assertion?.let { id ->
            val match = epubPackage.spine.indexOfFirst { it.itemrefId == id }
            if (match >= 0) return match
        }
        if (itemref.index % 2 != 0) return null
        val index = itemref.index / 2 - 1
        return index.takeIf { it in epubPackage.spine.indices }
    }

    fun narratedFragment(point: Point, overlayFragments: Set<String>): String? {
        if (overlayFragments.isEmpty()) return null
        var ancestor: EpubXhtmlDocument.Node? = point.element
        while (ancestor != null) {
            ancestor.elementId?.takeIf { it in overlayFragments }?.let { return it }
            ancestor = ancestor.parent
        }
        val pending = ArrayDeque(point.text?.let { point.element.children.drop(it.chunk) } ?: point.element.children)
        while (pending.isNotEmpty()) {
            val node = pending.removeFirst()
            node.elementId?.takeIf { it in overlayFragments }?.let { return it }
            node.children.asReversed().forEach(pending::addFirst)
        }
        return null
    }

    fun verifiedCfi(
        point: Point,
        document: EpubXhtmlDocument,
        spineIndex: Int,
        epubPackage: EpubPackage,
    ): String? {
        if (!document.isWellFormed) return null
        val localPath = document.localPath(point) ?: return null
        val cfi = string(epubPackage, spineIndex, localPath)
        val parsed = parse(cfi) ?: return null
        if (spineIndex(parsed, epubPackage) != spineIndex) return null
        val resolved = document.resolve(parsed.local) ?: return null
        return cfi.takeIf { resolved.isSameLocation(point) }
    }

    fun point(locator: JsonObject, document: EpubXhtmlDocument): Point? {
        val locations = locator.optObject("locations") ?: JsonObject(emptyMap())
        canonicalFullEpubCfi(epubCfi(locator))?.let(::parse)?.let { return document.walk(it.local) }

        val fragments = locations.optArray("fragments").orEmpty()
            .mapNotNull { it.stringOrNull() }
            .filter { !it.startsWith("t=") && normalizedEpubCfi(it) == null && !it.contains('=') }
        for (id in fragments) {
            document.element(id.removePrefix("#"))?.let { return Point(it, null) }
        }
        val domRangeStart = locations.optObject("domRange")?.optObject("start")
        domRangeStart?.let { start ->
            val element = simpleIdSelector(start.optString("cssSelector"))?.let(document::element)
            val textNodeIndex = start.optInt("textNodeIndex")
            if (element != null && textNodeIndex != null) {
                document.textPoint(element, textNodeIndex, start.optInt("charOffset") ?: 0)?.let { return it }
            }
        }
        for (selector in listOf(locations.optString("cssSelector"), domRangeStart?.optString("cssSelector"))) {
            simpleIdSelector(selector)?.let(document::element)?.let { return Point(it, null) }
        }

        val index = document.textIndex()
        val text = locator.optObject("text")
        text?.optString("highlight")?.let { highlight ->
            index.point(highlight, text.optString("before"))?.let { return it }
        }
        return index.point(fraction = locations.optDouble("progression") ?: 0.0)
    }

    fun readiumLocator(
        point: Point,
        document: EpubXhtmlDocument,
        href: String,
        totalProgression: Double,
        overlayFragments: Set<String>,
    ): JsonObject {
        val index = document.textIndex()
        val offset = index.offset(point)
        val fragment = narratedFragment(point, overlayFragments)
        val quote = if (fragment == null) index.quote(offset) else null
        return buildJsonObject {
            put("href", href)
            put("type", "application/xhtml+xml")
            if (quote != null) {
                put("text", buildJsonObject {
                    put("highlight", quote.first)
                    if (quote.second.isNotEmpty()) put("before", quote.second)
                })
            }
            put("locations", buildJsonObject {
                put("progression", if (index.length > 0) (offset.toDouble() / index.length).coerceIn(0.0, 1.0) else 0.0)
                put("totalProgression", totalProgression.coerceIn(0.0, 1.0))
                if (fragment != null) {
                    put("fragments", JsonArray(listOf(JsonPrimitive(fragment))))
                    idSelector(fragment)?.let { put("cssSelector", it) }
                }
            })
        }
    }

    fun jsonObject(value: String): JsonObject? =
        try {
            Json.parseToJsonElement(value) as? JsonObject
        } catch (_: SerializationException) {
            null
        }

    fun providerCfi(locatorJson: String, epubFile: File): String? {
        val locator = jsonObject(locatorJson) ?: return null
        return EpubArchive.open(epubFile).use { archive ->
            val spineIndex = canonicalFullEpubCfi(epubCfi(locator))?.let(::parse)
                ?.let { spineIndex(it, archive.epubPackage) }
                ?: locator.optString("href")?.let(archive.epubPackage::spineIndex)
                ?: return@use null
            val document = archive.document(spineIndex)
            val point = point(locator, document) ?: return@use null
            verifiedCfi(point, document, spineIndex, archive.epubPackage)
        }
    }

    fun readiumLocatorJson(cfi: String, totalProgression: Double, epubFile: File): String? {
        val parsed = parse(cfi) ?: return null
        return EpubArchive.open(epubFile).use { archive ->
            val spineIndex = spineIndex(parsed, archive.epubPackage) ?: return@use null
            val document = archive.document(spineIndex)
            if (!document.isWellFormed) return@use null
            val point = document.resolve(parsed.local) ?: return@use null
            readiumLocator(
                point = point,
                document = document,
                href = archive.epubPackage.spine[spineIndex].href,
                totalProgression = totalProgression,
                overlayFragments = archive.overlayFragmentIds(spineIndex),
            ).toString()
        }
    }

    fun normalizedEpubCfi(value: String?): String? {
        val trimmed = value?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return when {
            trimmed.startsWith("epubcfi(") && trimmed.endsWith(")") -> trimmed
            trimmed.startsWith("/") -> "epubcfi($trimmed)"
            else -> null
        }
    }

    private fun canonicalFullEpubCfi(value: String?): String? {
        val cfi = normalizedEpubCfi(value) ?: return null
        val inner = cfi.substring("epubcfi(".length, cfi.length - 1)
        return cfi.takeIf { inner.startsWith("/6/") && inner.contains('!') }
    }

    private fun epubCfi(locator: JsonObject): String? {
        val locations = locator.optObject("locations") ?: return null
        normalizedEpubCfi(locations.optString("cfi"))?.let { return it }
        return locations.optArray("fragments")?.firstNotNullOfOrNull { normalizedEpubCfi(it.stringOrNull()) }
    }

    private val CSS_IDENTIFIER = Regex("[A-Za-z_][A-Za-z0-9_-]*")

    internal fun idSelector(id: String): String? = "#$id".takeIf { CSS_IDENTIFIER.matches(id) }

    internal fun simpleIdSelector(selector: String?): String? =
        selector?.takeIf { it.length > 1 && it.startsWith("#") && it.drop(1).none { c -> c in " >.:[" } }
            ?.drop(1)
}

class EpubPackage(
    val spineStep: Int,
    val spine: List<SpineItem>,
) {
    data class SpineItem(
        val itemrefId: String?,
        val href: String,
        val mediaOverlayHref: String?,
        val isLinear: Boolean,
        val mediaOverlayDuration: Double? = null,
    )

    fun spineIndex(href: String): Int? {
        val target = normalized(href)
        if (target.isEmpty()) return null
        spine.indexOfFirst { normalized(it.href) == target }.takeIf { it >= 0 }?.let { return it }
        return spine.indexOfFirst { item ->
            val candidate = normalized(item.href)
            candidate.endsWith("/$target") || target.endsWith("/$candidate")
        }.takeIf { it >= 0 }
    }

    companion object {
        fun parse(opf: String, opfPath: String): EpubPackage {
            val handler = SpineHandler()
            parseXml(opf, handler)
            val baseDirectory = opfPath.substringBeforeLast('/', "")
            fun archivePath(href: String): String {
                val decoded = percentDecoded(href)
                return resolvingDotSegments(if (baseDirectory.isEmpty()) decoded else "$baseDirectory/$decoded")
            }
            return EpubPackage(
                spineStep = handler.spineStep,
                spine = handler.itemrefs.mapNotNull { itemref ->
                    val item = handler.manifest[itemref.idref] ?: return@mapNotNull null
                    val overlay = item.mediaOverlay?.let(handler.manifest::get)
                    SpineItem(
                        itemrefId = itemref.id,
                        href = archivePath(item.href),
                        mediaOverlayHref = overlay?.let { archivePath(it.href) },
                        isLinear = itemref.isLinear,
                        mediaOverlayDuration = item.mediaOverlay?.let(handler.durations::get),
                    )
                },
            )
        }

        fun resolvingDotSegments(path: String): String {
            val components = ArrayList<String>()
            for (component in path.split('/')) {
                when (component) {
                    "", "." -> Unit
                    ".." -> if (components.isNotEmpty()) components.removeAt(components.lastIndex)
                    else -> components += component
                }
            }
            return components.joinToString("/")
        }

        internal fun percentDecoded(value: String): String =
            try {
                URLDecoder.decode(value.replace("+", "%2B"), "UTF-8")
            } catch (_: IllegalArgumentException) {
                value
            }

        private fun normalized(href: String): String =
            resolvingDotSegments(percentDecoded(href.substringBefore('#')))
    }

    private class SpineHandler : XmlHandler() {
        class ManifestItem(val href: String, val mediaOverlay: String?)
        class Itemref(val idref: String, val id: String?, val isLinear: Boolean)

        val manifest = HashMap<String, ManifestItem>()
        val itemrefs = ArrayList<Itemref>()
        val durations = HashMap<String, Double>()
        var spineStep = 6
        private var depth = 0
        private var packageChildren = 0
        private var durationTarget: String? = null
        private val durationText = StringBuilder()

        override fun startElement(uri: String?, localName: String?, qName: String, attributes: Attributes) {
            depth++
            val tag = qName.substringAfterLast(':')
            if (depth == 2) {
                packageChildren++
                if (tag == "spine") spineStep = packageChildren * 2
            }
            when (tag) {
                "item" -> {
                    val id = attributes.getValue("id")
                    val href = attributes.getValue("href")
                    if (id != null && href != null) manifest[id] = ManifestItem(href, attributes.getValue("media-overlay"))
                }
                "itemref" -> attributes.getValue("idref")?.let { idref ->
                    itemrefs += Itemref(idref, attributes.getValue("id"), attributes.getValue("linear") != "no")
                }
                "meta" -> if (attributes.getValue("property") == "media:duration") {
                    durationTarget = attributes.getValue("refines")?.removePrefix("#")
                    durationText.setLength(0)
                }
            }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            if (durationTarget != null) durationText.appendRange(ch, start, start + length)
        }

        override fun endElement(uri: String?, localName: String?, qName: String) {
            depth--
            val target = durationTarget ?: return
            durationTarget = null
            clockSeconds(durationText.toString())?.let { durations[target] = it }
        }
    }
}

class EpubArchive private constructor(
    private val zip: ZipFile,
    val epubPackage: EpubPackage,
) : Closeable {
    fun html(path: String): String = decodeText(entryData(path))

    fun document(spineIndex: Int): EpubXhtmlDocument =
        EpubXhtmlDocument.parse(html(epubPackage.spine[spineIndex].href))

    fun overlayFragmentIds(spineIndex: Int): Set<String> {
        val item = epubPackage.spine[spineIndex]
        val smilPath = item.mediaOverlayHref ?: return emptySet()
        val smil = try {
            decodeText(entryData(smilPath))
        } catch (_: IOException) {
            return emptySet()
        }
        val smilDirectory = smilPath.substringBeforeLast('/', "")
        val documentName = item.href.substringAfterLast('/')
        return SMIL_TEXT_SRC.findAll(smil).mapNotNull { match ->
            val parts = match.groupValues[1].split('#', limit = 2)
            if (parts.size != 2) return@mapNotNull null
            val path = EpubPackage.percentDecoded(parts[0])
            val resolved = EpubPackage.resolvingDotSegments(if (smilDirectory.isEmpty()) path else "$smilDirectory/$path")
            parts[1].takeIf { resolved == item.href || resolved.substringAfterLast('/') == documentName }
        }.toSet()
    }

    fun entryData(path: String): ByteArray {
        val entry = zip.getEntry(path) ?: throw IOException("EPUB entry not found: $path")
        return zip.getInputStream(entry).use { it.readBytes() }
    }

    internal fun archivedLength(path: String): Long {
        val entry = zip.getEntry(path) ?: return 0L
        return if (entry.method == ZipEntry.DEFLATED) entry.compressedSize else entry.size
    }

    override fun close() = zip.close()

    companion object {
        private val SMIL_TEXT_SRC = Regex("""<(?:\w+:)?text\b[^>]*\bsrc\s*=\s*["']([^"']+)["']""")
        private val ROOTFILE = Regex("""<(?:\w+:)?rootfile\b[^>]*\bfull-path\s*=\s*["']([^"']+)["']""")

        fun open(file: File): EpubArchive {
            val zip = ZipFile(file)
            try {
                val container = zip.getEntry("META-INF/container.xml")
                    ?.let { entry -> zip.getInputStream(entry).use { decodeText(it.readBytes()) } }
                    ?: throw IOException("EPUB container.xml missing")
                val opfPath = ROOTFILE.find(container)?.groupValues?.get(1)
                    ?: throw IOException("EPUB container.xml missing OPF path")
                val opf = zip.getEntry(opfPath)
                    ?.let { entry -> zip.getInputStream(entry).use { decodeText(it.readBytes()) } }
                    ?: throw IOException("EPUB entry not found: $opfPath")
                return EpubArchive(zip, EpubPackage.parse(opf, opfPath))
            } catch (e: IOException) {
                zip.close()
                throw e
            }
        }

        private fun decodeText(data: ByteArray): String =
            try {
                StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(data)).toString()
            } catch (_: CharacterCodingException) {
                String(data, StandardCharsets.ISO_8859_1)
            }
    }
}

class EpubXhtmlDocument private constructor() {
    class TextRun(
        val elementsBefore: Int,
        val cfiOffset: Int,
        val text: String,
    )

    class Node(
        val tagName: String,
        val elementId: String?,
        val parent: Node?,
    ) {
        val children = ArrayList<Node>()
        val textRuns = ArrayList<TextRun>()
    }

    private var root: Node? = null
    private var body: Node? = null
    var isWellFormed = false
        private set

    fun element(id: String): Node? {
        val pending = ArrayDeque(listOfNotNull(root))
        while (pending.isNotEmpty()) {
            val node = pending.removeFirst()
            if (node.elementId == id) return node
            node.children.asReversed().forEach(pending::addFirst)
        }
        return null
    }

    fun localPath(point: EpubCfi.Point): String? {
        val steps = ArrayList<String>()
        var current = point.element
        while (current !== root) {
            val parent = current.parent ?: return null
            val position = parent.children.indexOfFirst { it === current }
            if (position < 0) return null
            steps.add(0, "/${(position + 1) * 2}${EpubCfi.assertion(current.elementId)}")
            current = parent
        }
        point.text?.let { steps += "/${it.chunk * 2 + 1}:${it.offset}" }
        return steps.takeIf { it.isNotEmpty() }?.joinToString("")
    }

    fun textPoint(element: Node, textNodeIndex: Int, charOffset: Int): EpubCfi.Point? {
        var remaining = textNodeIndex
        fun visit(node: Node): EpubCfi.Point? {
            var runIndex = 0
            for (chunk in 0..node.children.size) {
                while (runIndex < node.textRuns.size && node.textRuns[runIndex].elementsBefore == chunk) {
                    val run = node.textRuns[runIndex++]
                    if (remaining-- == 0) {
                        return EpubCfi.Point(node, EpubCfi.TextPosition(chunk, run.cfiOffset + charOffset.coerceIn(0, run.text.length)))
                    }
                }
                if (chunk < node.children.size) visit(node.children[chunk])?.let { return it }
            }
            return null
        }
        return visit(element)
    }

    fun resolve(steps: List<EpubCfi.Step>): EpubCfi.Point? {
        val last = steps.lastOrNull()
        if (last != null && last.index % 2 == 0) {
            last.assertion?.let(::element)?.let { return EpubCfi.Point(it, null) }
        }
        return walk(steps)
    }

    fun walk(steps: List<EpubCfi.Step>): EpubCfi.Point? {
        var node = root ?: return null
        if (steps.isEmpty()) return null
        for ((position, step) in steps.withIndex()) {
            if (step.index % 2 == 0) {
                node = node.children.getOrNull(step.index / 2 - 1) ?: return null
            } else {
                val chunk = (step.index - 1) / 2
                if (position != steps.lastIndex || chunk > node.children.size) return null
                return EpubCfi.Point(node, EpubCfi.TextPosition(chunk, step.offset ?: 0))
            }
        }
        return EpubCfi.Point(node, null)
    }

    fun textIndex(): EpubTextIndex = EpubTextIndex(body ?: root)

    private inner class Builder : XmlHandler() {
        private val stack = ArrayList<Node>()
        private val pendingText = StringBuilder()

        override fun startElement(uri: String?, localName: String?, qName: String, attributes: Attributes) {
            flushPendingText()
            val tag = qName.lowercase()
            val node = Node(tag, attributes.getValue("id"), stack.lastOrNull())
            stack.lastOrNull()?.children?.add(node)
            if (root == null) root = node
            if (body == null && tag == "body") body = node
            stack += node
        }

        override fun endElement(uri: String?, localName: String?, qName: String) {
            flushPendingText()
            if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex)
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            pendingText.appendRange(ch, start, start + length)
        }

        override fun ignorableWhitespace(ch: CharArray, start: Int, length: Int) {
            characters(ch, start, length)
        }

        override fun comment(ch: CharArray, start: Int, length: Int) = flushPendingText()

        override fun processingInstruction(target: String?, data: String?) = flushPendingText()

        override fun startCDATA() = flushPendingText()

        override fun endCDATA() = flushPendingText()

        override fun skippedEntity(name: String) {
            if (!name.startsWith("%")) throw SAXException("Undeclared entity: $name")
        }

        private fun flushPendingText() {
            if (pendingText.isEmpty()) return
            val node = stack.lastOrNull()
            if (node != null) {
                val elementsBefore = node.children.size
                val cfiOffset = node.textRuns.sumOf { if (it.elementsBefore == elementsBefore) it.text.length else 0 }
                node.textRuns += TextRun(elementsBefore, cfiOffset, pendingText.toString())
            }
            pendingText.setLength(0)
        }
    }

    companion object {
        fun parse(html: String): EpubXhtmlDocument {
            val document = EpubXhtmlDocument()
            val source = html.removePrefix("﻿")
            val xml = if (source.contains("<?xml") || source.contains("<html")) source else "<root>$source</root>"
            document.isWellFormed = parseXml(xml, document.Builder())
            return document
        }
    }
}

class EpubTextIndex(body: EpubXhtmlDocument.Node?) {
    class Segment(
        val node: EpubXhtmlDocument.Node,
        val chunk: Int,
        val chunkOffset: Int,
        val start: Int,
        val length: Int,
    )

    private val segments = ArrayList<Segment>()
    private val units = StringBuilder()
    private val elementStarts = IdentityHashMap<EpubXhtmlDocument.Node, Int>()
    private val elementEnds = IdentityHashMap<EpubXhtmlDocument.Node, Int>()

    val length: Int get() = units.length

    init {
        body?.let(::visit)
    }

    private fun visit(node: EpubXhtmlDocument.Node) {
        elementStarts[node] = units.length
        if (node.tagName != "script" && node.tagName != "style") {
            var runIndex = 0
            for (chunk in 0..node.children.size) {
                while (runIndex < node.textRuns.size && node.textRuns[runIndex].elementsBefore == chunk) {
                    val run = node.textRuns[runIndex]
                    segments += Segment(node, chunk, run.cfiOffset, units.length, run.text.length)
                    units.append(run.text)
                    runIndex++
                }
                if (chunk < node.children.size) visit(node.children[chunk])
            }
        }
        elementEnds[node] = units.length
    }

    fun offset(point: EpubCfi.Point): Int {
        val node = point.element
        val text = point.text ?: return elementStarts[node] ?: 0
        segments.lastOrNull { it.node === node && it.chunk == text.chunk && it.chunkOffset <= text.offset }?.let {
            return it.start + minOf(text.offset - it.chunkOffset, it.length)
        }
        if (text.chunk < node.children.size) return elementStarts[node.children[text.chunk]] ?: 0
        return elementEnds[node] ?: length
    }

    fun point(offset: Int): EpubCfi.Point? {
        var target = offset.coerceIn(0, length)
        while (target < length && isWhitespace(units[target])) target++
        val segment = segments.lastOrNull { it.start <= target && it.length > 0 } ?: segments.firstOrNull() ?: return null
        val within = (target - segment.start).coerceIn(0, segment.length)
        return EpubCfi.Point(segment.node, EpubCfi.TextPosition(segment.chunk, segment.chunkOffset + within))
    }

    fun point(fraction: Double): EpubCfi.Point? =
        point(kotlin.math.floor(fraction.coerceIn(0.0, 1.0) * length).toInt())

    fun point(quote: String, before: String?): EpubCfi.Point? {
        val needle = quote.filterNot(::isWhitespace)
        if (needle.length < 8) return null
        val haystack = StringBuilder()
        val rawOffsets = ArrayList<Int>()
        for (offset in 0 until length) {
            val unit = units[offset]
            if (isWhitespace(unit)) continue
            haystack.append(unit)
            rawOffsets += offset
        }
        if (haystack.length < needle.length) return null
        val context = before.orEmpty().filterNot(::isWhitespace)

        var firstMatch: Int? = null
        var start = haystack.indexOf(needle)
        while (start >= 0) {
            if (firstMatch == null) firstMatch = start
            if (context.isEmpty() || (start >= context.length && haystack.regionMatches(start - context.length, context, 0, context.length))) {
                return point(rawOffsets[start])
            }
            start = haystack.indexOf(needle, start + 1)
        }
        return firstMatch?.let { point(rawOffsets[it]) }
    }

    fun quote(offset: Int): Pair<String, String>? {
        var start = offset.coerceIn(0, length)
        while (start < length && isWhitespace(units[start])) start++
        val end = boundary(minOf(start + 60, length))
        if (end <= start) return null
        val beforeStart = boundary(maxOf(start - 30, 0))
        return units.substring(start, end) to units.substring(beforeStart, start)
    }

    private fun boundary(index: Int): Int =
        if (index > 0 && index < length && Character.isLowSurrogate(units[index])) index - 1 else index

    private fun isWhitespace(unit: Char): Boolean =
        unit == ' ' || unit == '\t' || unit == '\n' || unit == '\r' || unit == '\u000C' || unit == ' '
}

internal fun clockSeconds(value: String): Double? {
    val normalized = value.trim().lowercase()
    return when {
        normalized.isEmpty() -> null
        normalized.endsWith("ms") -> normalized.removeSuffix("ms").trim().toDoubleOrNull()?.div(1000.0)
        normalized.endsWith("min") -> normalized.removeSuffix("min").trim().toDoubleOrNull()?.times(60.0)
        normalized.endsWith("h") -> normalized.removeSuffix("h").trim().toDoubleOrNull()?.times(3600.0)
        normalized.endsWith("s") -> normalized.removeSuffix("s").trim().toDoubleOrNull()
        normalized.contains(':') -> {
            val parts = normalized.split(':').map { it.trim().toDoubleOrNull() ?: return null }
            if (parts.size > 3) return null
            parts.fold(0.0) { total, part -> total * 60.0 + part }
        }
        else -> normalized.toDoubleOrNull()
    }
}

internal open class XmlHandler : DefaultHandler2() {
    override fun resolveEntity(name: String?, publicId: String?, baseURI: String?, systemId: String?): InputSource =
        InputSource(StringReader(""))
}

private val saxParserFactory: SAXParserFactory by lazy {
    SAXParserFactory.newInstance().apply {
        isNamespaceAware = false
        isValidating = false
        try {
            setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false)
        } catch (_: Exception) {
        }
    }
}

internal fun parseXml(xml: String, handler: XmlHandler): Boolean {
    val reader = synchronized(saxParserFactory) { saxParserFactory.newSAXParser() }.xmlReader
    reader.contentHandler = handler
    reader.errorHandler = handler
    reader.entityResolver = handler
    reader.setProperty("http://xml.org/sax/properties/lexical-handler", handler)
    return try {
        reader.parse(InputSource(StringReader(xml)))
        true
    } catch (_: SAXException) {
        false
    }
}
