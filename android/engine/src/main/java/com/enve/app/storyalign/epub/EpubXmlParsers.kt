package com.enve.app.storyalign.epub

import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import org.jsoup.parser.Parser

class StoryAlignParseException(message: String) : Exception(message)

private fun String.localName(): String = substringAfterLast(':')
private fun Element.localTag(): String = tagName().localName()
private fun Element.childrenByLocal(name: String): List<Element> =
    children().filter { it.localTag().equals(name, ignoreCase = true) }
private fun Element.descendantsByLocal(name: String): List<Element> =
    getAllElements().filter { it.localTag().equals(name, ignoreCase = true) }

internal fun parseXmlDocument(bytes: ByteArray): Document =
    Jsoup.parse(String(bytes, Charsets.UTF_8), "", Parser.xmlParser())

fun parseEpubContainer(bytes: ByteArray): String {
    val doc = parseXmlDocument(bytes)
    val opf = doc.descendantsByLocal("rootfile").firstOrNull()?.attr("full-path").orEmpty()
    if (opf.isEmpty()) throw StoryAlignParseException("Missing opfPath in container")
    return opf
}

fun parseEpubManifest(opf: Document): List<OpfManifestItem> {
    val manifest = opf.descendantsByLocal("manifest").firstOrNull() ?: return emptyList()
    return manifest.childrenByLocal("item").mapNotNull { item ->
        val id = item.attr("id").ifEmpty { return@mapNotNull null }
        val href = item.attr("href").ifEmpty { return@mapNotNull null }
        val mediaType = item.attr("media-type").ifEmpty { null }
        val props = item.attr("properties").split(" ").filter { it.isNotEmpty() }.ifEmpty { null }
        OpfManifestItem(id, href, mediaType, props)
    }
}

fun parseEpubSpine(opf: Document): EpubSpine {
    val spineEl = opf.descendantsByLocal("spine").firstOrNull()
    val toc = spineEl?.attr("toc").orEmpty()
    val items = ArrayList<EpubSpineItem>()
    spineEl?.childrenByLocal("itemref")?.forEachIndexed { index, ref ->
        val idref = ref.attr("idref").ifEmpty { return@forEachIndexed }
        items.add(EpubSpineItem(idref = idref, id = ref.attr("id").ifEmpty { null }, index = index))
    }
    return EpubSpine(toc = toc, items = items)
}

fun parseEpubMetaInfo(opf: Document): EpubMetaInfo {
    opf.descendantsByLocal("contributor").firstOrNull { it.attr("id").startsWith("storyalign-contributor") }?.let {
        throw StoryAlignParseException("This EPUB has already been aligned by StoryAlign. Please use a different EPUB file.")
    }
    opf.descendantsByLocal("meta").firstOrNull { it.attr("property").lowercase() == "storyteller:media-overlays-modified" }?.let {
        throw StoryAlignParseException("This EPUB has already been aligned by Storyteller. Please use a different EPUB file.")
    }
    val meta = EpubMetaInfo()
    meta.version = opf.descendantsByLocal("package").firstOrNull()?.attr("version")?.ifEmpty { null }
    val metadata = opf.descendantsByLocal("metadata").firstOrNull() ?: return meta
    for (el in metadata.getAllElements()) {
        val txt = el.text().trim()
        if (txt.isEmpty()) continue
        when (el.localTag().lowercase()) {
            "identifier" -> meta.identifier = meta.identifier ?: txt
            "title" -> meta.title = meta.title ?: txt
            "creator" -> meta.creator = meta.creator ?: txt
            "language" -> meta.language = meta.language ?: txt
            "publisher" -> meta.publisher = meta.publisher ?: txt
            "date" -> meta.date = meta.date ?: txt
            "subject" -> meta.subject = meta.subject ?: txt
        }
    }
    return meta
}

fun parseEpubGuide(opf: Document): List<EpubGuideItem> {
    val guide = opf.descendantsByLocal("guide").firstOrNull() ?: return emptyList()
    return guide.childrenByLocal("reference").mapNotNull { ref ->
        val type = ref.attr("type").ifEmpty { return@mapNotNull null }
        val href = ref.attr("href").ifEmpty { return@mapNotNull null }
        EpubGuideItem(type = type, title = ref.attr("title").ifEmpty { null }, href = href)
    }
}

fun parseEpubNav(bytes: ByteArray, navHref: String): EpubNav {
    val doc = parseXmlDocument(bytes)
    val landmarks = ArrayList<EpubLandmark>()
    val toc = ArrayList<EpubTocEntry>()
    for (nav in doc.descendantsByLocal("nav")) {
        when (nav.attr("epub:type")) {
            "landmarks" -> for (a in nav.descendantsByLocal("a")) {
                val href = a.attr("href")
                if (href.isEmpty()) continue
                a.attr("epub:type").split(" ").filter { it.isNotEmpty() }.forEach { word ->
                    EpubChapterRole.fromRaw(word)?.let { landmarks.add(EpubLandmark(href, it)) }
                }
            }
            "toc" -> for (a in nav.descendantsByLocal("a")) {
                val href = a.attr("href")
                if (href.isEmpty()) continue
                val title = a.text().trim()
                if (title.isEmpty()) continue
                toc.add(EpubTocEntry(href = href, title = title))
            }
        }
    }
    return EpubNav(tocFileHref = navHref, landmarks = landmarks, toc = toc)
}

fun parseEpubNcx(bytes: ByteArray, ncxHref: String, ncxId: String): Epub2Ncx {
    val doc = parseXmlDocument(bytes)
    val docTitle = doc.descendantsByLocal("docTitle").firstOrNull()
        ?.childrenByLocal("text")?.firstOrNull()?.text()?.trim().orEmpty()
    val navMap = doc.descendantsByLocal("navMap").firstOrNull()
    val navPoints = navMap?.childrenByLocal("navPoint")?.map { parseNavPoint(it) } ?: emptyList()
    return Epub2Ncx(docTitle = docTitle, navPoints = navPoints, tocFileHref = ncxHref, ncxId = ncxId)
}

private fun parseNavPoint(el: Element): NcxNavPoint {
    val label = el.childrenByLocal("navLabel").firstOrNull()
        ?.childrenByLocal("text")?.firstOrNull()?.text()?.trim().orEmpty()
    val src = el.childrenByLocal("content").firstOrNull()?.attr("src")?.ifEmpty { null }
    val children = el.childrenByLocal("navPoint").map { parseNavPoint(it) }.toMutableList()
    return NcxNavPoint(label = label, src = src, children = children)
}

object EpubOpfResolver {
    fun navManifestItem(items: List<OpfManifestItem>): OpfManifestItem? =
        items.firstOrNull { it.properties?.contains("nav") == true }

    fun ncxManifestItem(items: List<OpfManifestItem>, spine: EpubSpine): OpfManifestItem? {
        if (spine.toc.isNotEmpty()) items.firstOrNull { it.id == spine.toc }?.let { return it }
        items.firstOrNull { it.mediaType == EpubMediaTypes.NCX_XML }?.let { return it }
        return items.firstOrNull { it.properties?.contains("ncx") == true }
    }
}
