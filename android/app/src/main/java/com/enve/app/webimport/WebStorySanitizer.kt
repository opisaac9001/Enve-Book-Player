package com.enve.app.webimport

import okhttp3.HttpUrl
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import org.jsoup.nodes.Entities
import org.jsoup.nodes.TextNode
import org.jsoup.safety.Cleaner
import org.jsoup.safety.Safelist

internal object WebStorySanitizer {
    private const val REMOVED_ELEMENTS =
        "script, style, noscript, template, iframe, frame, frameset, object, embed, applet, portal, " +
            "form, input, button, select, textarea, dialog, nav, aside, footer, header, menu, " +
            "svg, math, canvas, video, audio, source, track, map, link, meta, base"
    private const val MAX_ALT_LENGTH = 500

    private const val HIDDEN_ELEMENTS =
        "[hidden], [aria-hidden=true], [style~=(?i)display\\s*:\\s*none], [style~=(?i)visibility\\s*:\\s*hidden]"

    private val invalidXmlChars = Regex("[^\\u0009\\u000A\\u000D\\u0020-\\uD7FF\\uE000-\\uFFFD\\x{10000}-\\x{10FFFF}]")
    private val whitespace = Regex("\\s+")

    private val safelist: Safelist = Safelist()
        .addTags(
            "p", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "code",
            "em", "i", "strong", "b", "u", "s", "del", "ins", "sub", "sup", "small", "mark",
            "abbr", "cite", "q", "ul", "ol", "li", "dl", "dt", "dd", "table", "caption",
            "thead", "tbody", "tfoot", "tr", "th", "td", "figure", "figcaption", "div", "span", "a",
        )
        .addAttributes("a", "href")
        .addProtocols("a", "href", "http", "https")
        .addAttributes("td", "colspan", "rowspan")
        .addAttributes("th", "colspan", "rowspan")
        .addAttributes("ol", "start")

    fun sanitize(content: Element, baseUrl: HttpUrl, hiddenClasses: Set<String>, title: String?): String? {
        val shell = Document.createShell(baseUrl.toString())
        val working = shell.body()
        working.appendChild(content.clone())
        working.select(HIDDEN_ELEMENTS).remove()
        hiddenClasses.forEach { name -> working.getElementsByClass(name).remove() }
        working.select(REMOVED_ELEMENTS).remove()
        for (image in working.select("img")) {
            val alt = plainText(image.attr("alt"), MAX_ALT_LENGTH)
            if (alt == null) image.remove() else image.replaceWith(TextNode(" $alt "))
        }

        val clean = Cleaner(safelist).clean(shell)
        val body = clean.body()
        body.select("span").unwrap()
        body.traverse { node, _ ->
            when (node) {
                is TextNode -> node.text(xmlSafe(node.wholeText))
                is Element -> node.attributes().forEach { it.setValue(xmlSafe(it.value)) }
            }
        }
        if (title != null) dropLeadingTitle(body, title)
        body.select("p").filter { !it.hasText() }.forEach { it.remove() }
        if (!body.hasText()) return null
        clean.outputSettings()
            .syntax(Document.OutputSettings.Syntax.xml)
            .escapeMode(Entities.EscapeMode.xhtml)
            .charset(Charsets.UTF_8)
            .prettyPrint(false)
        return xmlSafe(body.html())
    }

    fun xmlSafe(text: String): String = text.replace(invalidXmlChars, "")

    fun plainText(text: String?, maxLength: Int): String? =
        text?.let { xmlSafe(it).replace(whitespace, " ").trim().take(maxLength) }?.ifBlank { null }

    private fun dropLeadingTitle(body: Element, title: String) {
        var container = body
        while (true) {
            val first = container.childNodes().firstOrNull { it !is TextNode || !it.isBlank } as? Element ?: return
            when (first.tagName()) {
                "div" -> container = first
                "h1", "h2", "h3" -> {
                    if (first.text().normalized() == title.normalized()) first.remove()
                    return
                }
                else -> return
            }
        }
    }

    private fun String.normalized() = replace(whitespace, " ").trim().lowercase()
}
