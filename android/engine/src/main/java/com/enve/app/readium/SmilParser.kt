package com.enve.app.readium

import java.io.ByteArrayInputStream
import javax.xml.parsers.DocumentBuilderFactory
import org.readium.r2.shared.util.Url
import org.w3c.dom.Element
import org.w3c.dom.Node

data class SmilClip(
    val textHref: String,
    val textFragmentId: String?,
    val audioHref: String,
    val clipBeginMs: Long,
    val clipEndMs: Long?,
    val resourceProgression: Double? = null,

    val skippable: Boolean = false,
)

data class SmilDocument(
    val smilHref: String,
    val clips: List<SmilClip>,
)

object SmilParser {
    private const val OPS_NS = "http://www.idpf.org/2007/ops"
    private val SKIPPABLE_TYPES = setOf(
        "footnote", "endnote", "note", "rearnote", "annotation", "sidebar", "pagebreak",
    )

    fun parse(smilXml: String, smilHref: String): SmilDocument {
        val baseHref = parseUrl(smilHref)
            ?: throw IllegalArgumentException("Invalid SMIL href: $smilHref")

        val document = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
        }.newDocumentBuilder().parse(ByteArrayInputStream(smilXml.toByteArray()))

        val clips = mutableListOf<SmilClip>()
        collectParNodes(document.documentElement, baseHref, clips)

        return SmilDocument(
            smilHref = normalizeHref(baseHref.toString()),
            clips = clips,
        )
    }

    private fun collectParNodes(node: Node?, baseHref: Url, clips: MutableList<SmilClip>) {
        if (node == null) return

        if (node.nodeType == Node.ELEMENT_NODE) {
            val element = node as Element
            if (element.localName.equals("par", ignoreCase = true)) {
                parsePar(element, baseHref)?.let(clips::add)
            }
        }

        val children = node.childNodes
        for (index in 0 until children.length) {
            collectParNodes(children.item(index), baseHref, clips)
        }
    }

    private fun parsePar(parElement: Element, baseHref: Url): SmilClip? {
        val textElement = firstDescendant(parElement, "text") ?: return null
        val audioElement = firstDescendant(parElement, "audio") ?: return null

        val rawTextSrc = textElement.getAttribute("src").orEmpty().ifBlank { return null }
        val rawAudioSrc = audioElement.getAttribute("src").orEmpty().ifBlank { return null }

        val resolvedText = resolveHref(baseHref, rawTextSrc) ?: return null
        val resolvedAudio = resolveHref(baseHref, rawAudioSrc) ?: return null

        val mediaFragment = parseTimeFragment(resolvedAudio.fragment)
        val beginMs = audioElement.getAttribute("clipBegin")
            .takeIf { it.isNotBlank() }
            ?.let(::parseClockValueMs)
            ?: mediaFragment.first
            ?: 0L
        val endMs = audioElement.getAttribute("clipEnd")
            .takeIf { it.isNotBlank() }
            ?.let(::parseClockValueMs)
            ?: mediaFragment.second

        return SmilClip(
            textHref = normalizeHref(resolvedText.removeFragment().toString()),
            textFragmentId = resolvedText.fragment?.removePrefix("#")?.takeIf { it.isNotBlank() },
            audioHref = normalizeHref(resolvedAudio.removeFragment().toString()),
            clipBeginMs = beginMs.coerceAtLeast(0L),
            clipEndMs = endMs?.takeIf { it > beginMs },
            skippable = isSkippable(parElement) || isSkippable(textElement),
        )
    }

    private fun isSkippable(element: Element): Boolean {
        var node: Node? = element
        while (node is Element) {
            val types = node.getAttributeNS(OPS_NS, "type")
                .ifBlank { node.getAttribute("epub:type") }
            if (types.isNotBlank() && types.split(' ').any { it.trim().lowercase() in SKIPPABLE_TYPES }) {
                return true
            }
            node = node.parentNode
        }
        return false
    }

    private fun firstDescendant(root: Element, tagName: String): Element? {
        val children = root.childNodes
        for (index in 0 until children.length) {
            val child = children.item(index)
            if (child.nodeType != Node.ELEMENT_NODE) continue

            val childElement = child as Element
            if (childElement.localName.equals(tagName, ignoreCase = true)) {
                return childElement
            }

            firstDescendant(childElement, tagName)?.let { return it }
        }
        return null
    }

    private fun resolveHref(baseHref: Url, rawHref: String): Url? {
        val href = parseUrl(rawHref) ?: return null
        return baseHref.resolve(href)
    }

    private fun parseTimeFragment(fragment: String?): Pair<Long?, Long?> {
        if (fragment.isNullOrBlank()) return null to null

        val timeRange = fragment.substringAfter("t=", missingDelimiterValue = "")
            .takeIf { it.isNotBlank() }
            ?: return null to null

        val parts = timeRange.split(',')
        val begin = parts.getOrNull(0)?.takeIf { it.isNotBlank() }?.let(::parseClockValueMs)
        val end = parts.getOrNull(1)?.takeIf { it.isNotBlank() }?.let(::parseClockValueMs)
        return begin to end
    }

    private fun parseClockValueMs(value: String): Long {
        val normalized = value.trim().lowercase()
        return when {
            normalized.endsWith("ms") -> normalized.removeSuffix("ms").trim().toDoubleOrNull()?.toLong() ?: 0L
            normalized.endsWith("s") -> ((normalized.removeSuffix("s").trim().toDoubleOrNull() ?: 0.0) * 1000.0).toLong()
            normalized.contains(':') -> parseClockComponents(normalized)
            else -> ((normalized.toDoubleOrNull() ?: 0.0) * 1000.0).toLong()
        }
    }

    private fun parseClockComponents(value: String): Long {
        val parts = value.split(':').map { it.trim() }
        if (parts.isEmpty()) return 0L

        var totalSeconds = 0.0
        val secondsPart = parts.lastOrNull()?.toDoubleOrNull() ?: 0.0
        totalSeconds += secondsPart

        val minutesPart = parts.dropLast(1).lastOrNull()?.toDoubleOrNull() ?: 0.0
        totalSeconds += minutesPart * 60.0

        val hoursPart = parts.dropLast(2).lastOrNull()?.toDoubleOrNull() ?: 0.0
        totalSeconds += hoursPart * 3600.0

        return (totalSeconds * 1000.0).toLong()
    }

    private fun normalizeHref(href: String): String =
        parseUrl(href)?.normalize()?.removeFragment()?.toString() ?: href

    private fun parseUrl(rawHref: String): Url? =
        Url(rawHref) ?: Url.fromDecodedPath(rawHref)
}