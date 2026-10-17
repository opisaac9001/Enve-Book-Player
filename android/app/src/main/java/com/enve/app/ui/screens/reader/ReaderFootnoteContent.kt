package com.enve.app.ui.screens.reader

import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.safety.Safelist

private val NOTE_TYPES = setOf("footnote", "endnote", "rearnote", "note")
private val NOTE_ROLES = setOf("doc-footnote", "doc-endnote")
private val NOTE_CONTAINER_TYPES = setOf("footnotes", "endnotes", "rearnotes")
private val NOTE_CONTAINER_CLASSES = setOf("footnotes", "endnotes")
private val INLINE_TAGS = setOf("a", "span", "sup", "sub", "b", "i", "em", "strong", "small")
private val NON_NOTE_TAGS = setOf("body", "h1", "h2", "h3", "h4", "h5", "h6")

internal fun epubLinkIsNoteRef(sourceHtml: String, targetsLink: (String) -> Boolean): Boolean =
    Jsoup.parse(sourceHtml).select("a[href]").any { anchor ->
        targetsLink(anchor.attr("href")) &&
            (anchor.attr("role").lowercase() == "doc-noteref" || "noteref" in anchor.epubTypes())
    }

internal fun epubNoteHtml(documentHtml: String, fragmentId: String, linkedAsNoteRef: Boolean): String? {
    val target = Jsoup.parse(documentHtml).getElementById(fragmentId) ?: return null
    val note = if (target.normalName() in INLINE_TAGS) {
        target.parents().firstOrNull { it.normalName() !in INLINE_TAGS } ?: return null
    } else {
        target
    }
    if (note.normalName() in NON_NOTE_TAGS || note.isNoteContainer()) return null
    val isNote = linkedAsNoteRef || target.isNoteElement() || note.isNoteElement() ||
        note.parents().any { it.isNoteContainer() }
    if (!isNote) return null
    val content = note.clone()
    content.select("a").filter { it.isBacklink() }.forEach(Element::remove)
    return Jsoup.clean(content.html(), Safelist.relaxed()).takeIf { Jsoup.parse(it).text().isNotBlank() }
}

private fun Element.epubTypes(): Set<String> = tokens(attr("epub:type"))

private fun Element.classTokens(): Set<String> = tokens(className())

private fun tokens(value: String): Set<String> =
    value.split(' ').filter(String::isNotBlank).map(String::lowercase).toSet()

private fun Element.isNoteElement(): Boolean =
    normalName() == "aside" || epubTypes().any(NOTE_TYPES::contains) || attr("role").lowercase() in NOTE_ROLES ||
        classTokens().any { it.contains("footnote") || it.contains("endnote") }

private fun Element.isNoteContainer(): Boolean =
    epubTypes().any(NOTE_CONTAINER_TYPES::contains) || attr("role").lowercase() == "doc-endnotes" ||
        classTokens().any(NOTE_CONTAINER_CLASSES::contains)

private fun Element.isBacklink(): Boolean =
    attr("role").lowercase() == "doc-backlink" || "backlink" in epubTypes()
