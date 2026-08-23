package com.enve.app.data.export

import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.ReaderAnnotation
import org.json.JSONArray
import org.json.JSONObject
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

object AnnotationExporter {

    enum class Format { MARKDOWN, JSON, PLAIN_TEXT, CSV, HTML, W3C_ANNOTATIONS }

    fun export(
        annotations: List<ReaderAnnotation>,
        bookTitle: String? = null,
        bookAuthor: String? = null,
        format: Format,
    ): String = when (format) {
        Format.MARKDOWN          -> markdown(annotations, bookTitle, bookAuthor)
        Format.JSON              -> json(annotations)
        Format.PLAIN_TEXT        -> plainText(annotations)
        Format.CSV               -> csv(annotations)
        Format.HTML              -> html(annotations, bookTitle, bookAuthor)
        Format.W3C_ANNOTATIONS   -> w3cAnnotations(annotations, bookTitle, bookAuthor)
    }

    fun mimeType(format: Format): String = when (format) {
        Format.MARKDOWN          -> "text/markdown"
        Format.JSON              -> "application/json"
        Format.PLAIN_TEXT        -> "text/plain"
        Format.CSV               -> "text/csv"
        Format.HTML              -> "text/html"

        Format.W3C_ANNOTATIONS   -> "application/ld+json"
    }

    fun extension(format: Format): String = when (format) {
        Format.MARKDOWN          -> "md"
        Format.JSON              -> "json"
        Format.PLAIN_TEXT        -> "txt"
        Format.CSV               -> "csv"
        Format.HTML              -> "html"

        Format.W3C_ANNOTATIONS   -> "annotation"
    }

    private fun markdown(
        annotations: List<ReaderAnnotation>,
        bookTitle: String?,
        bookAuthor: String?,
    ): String = buildString {
        if (!bookTitle.isNullOrBlank()) {
            append("# ").append(bookTitle).append("\n")
            if (!bookAuthor.isNullOrBlank()) append("*by ").append(bookAuthor).append("*\n")
            append("\n")
        }
        val grouped = annotations
            .filter { it.deletedAt == null }
            .sortedBy { it.createdAt }
            .groupBy { AnnotationKind.parse(it.kind) }

        listOf(AnnotationKind.HIGHLIGHT, AnnotationKind.NOTE, AnnotationKind.BOOKMARK).forEach { kind ->
            val list = grouped[kind].orEmpty()
            if (list.isEmpty()) return@forEach
            append("## ").append(kind.label).append("s\n\n")
            list.forEach { a ->
                if (a.selectedText.isNotBlank()) {
                    append("> ")
                    append(a.selectedText.replace("\n", "\n> "))
                    append("\n\n")
                }
                if (a.note.isNotBlank()) {
                    append(a.note).append("\n\n")
                }
                val parts = mutableListOf<String>()
                a.chapterId?.takeIf { it.isNotBlank() }?.let { parts += it }
                parts += DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(a.createdAt))
                append("- ").append(parts.joinToString(", ")).append("\n\n")
                append("---\n\n")
            }
        }
    }.trimEnd()

    private fun json(annotations: List<ReaderAnnotation>): String {
        val arr = JSONArray()
        annotations.filter { it.deletedAt == null }.forEach { a ->
            arr.put(JSONObject().apply {
                put("id", a.id)
                put("bookId", a.bookId)
                put("kind", a.kind)
                put("media", a.media)
                put("style", a.style)
                put("colorHex", a.colorHex)
                a.locatorJson?.let { put("locatorJson", it) }
                a.pdfPage?.let { put("pdfPage", it) }
                a.pdfRectsJson?.let { put("pdfRectsJson", it) }
                a.cbzPage?.let { put("cbzPage", it) }
                a.audioPositionMs?.let { put("audioPositionMs", it) }
                a.chapterId?.let { put("chapterId", it) }
                put("selectedText", a.selectedText)
                put("note", a.note)
                put("tags", JSONArray(a.tagsJson))
                put("createdAt", a.createdAt)
                put("updatedAt", a.updatedAt)
            })
        }
        return arr.toString(2)
    }

    private fun plainText(annotations: List<ReaderAnnotation>): String =
        annotations
            .filter { it.deletedAt == null }
            .sortedBy { it.createdAt }
            .joinToString("\n\n") { a ->
                buildString {
                    if (a.selectedText.isNotBlank()) append(a.selectedText)
                    if (a.note.isNotBlank()) {
                        if (isNotEmpty()) append("\n  ")
                        append(a.note)
                    }
                }.ifBlank { "[empty annotation]" }
            }

    private fun csv(annotations: List<ReaderAnnotation>): String = buildString {

        val cols = listOf(
            "id", "kind", "style", "colorHex", "chapter", "selectedText", "note",
            "tags", "createdAtIso", "updatedAtIso", "cfi", "totalProgression",
        )
        append(cols.joinToString(",") { csvField(it) }).append("\n")
        annotations
            .filter { it.deletedAt == null }
            .sortedBy { it.createdAt }
            .forEach { a ->
                val tags = runCatching {
                    val arr = JSONArray(a.tagsJson)
                    buildList { for (i in 0 until arr.length()) arr.optString(i)?.takeIf { it.isNotBlank() }?.let(::add) }
                }.getOrDefault(emptyList()).joinToString("; ")
                val row = listOf(
                    a.id, a.kind, a.style, a.colorHex, a.chapterId.orEmpty(),
                    a.selectedText, a.note, tags,
                    iso8601(a.createdAt), iso8601(a.updatedAt),
                    a.cfi.orEmpty(), a.totalProgression?.toString().orEmpty(),
                )
                append(row.joinToString(",") { csvField(it) }).append("\n")
            }
    }

    private fun csvField(v: String): String = "\"" + v.replace("\"", "\"\"") + "\""

    private fun html(
        annotations: List<ReaderAnnotation>,
        bookTitle: String?,
        bookAuthor: String?,
    ): String = buildString {
        append("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">")
        append("<title>").append(htmlEscape(bookTitle ?: "Annotations")).append("</title>")
        append("<style>")
        append("body{font-family:-apple-system,system-ui,sans-serif;max-width:42rem;margin:2rem auto;padding:0 1rem;color:#222;line-height:1.5}")
        append("h1{font-size:1.6rem;margin-bottom:.2rem}h2{margin-top:2rem;border-bottom:1px solid #ddd;padding-bottom:.3rem}")
        append(".meta{color:#888;font-size:.85rem;margin-bottom:1.5rem}")
        append(".ann{margin:1.4rem 0;padding:.8rem 1rem;border-left:4px solid;border-radius:4px;background:#fafafa}")
        append(".quote{font-style:italic;color:#444}.note{margin-top:.5rem;white-space:pre-wrap}")
        append(".tags{margin-top:.4rem}.tag{display:inline-block;background:#eee;border-radius:4px;padding:1px 6px;font-size:.8rem;margin-right:.3rem}")
        append(".footer{color:#999;font-size:.8rem;margin-top:.6rem}")
        append("</style></head><body>")
        append("<h1>").append(htmlEscape(bookTitle ?: "Annotations")).append("</h1>")
        if (!bookAuthor.isNullOrBlank()) append("<div class=\"meta\">by ").append(htmlEscape(bookAuthor)).append("</div>")
        val grouped = annotations.filter { it.deletedAt == null }
            .sortedBy { it.createdAt }
            .groupBy { AnnotationKind.parse(it.kind) }
        listOf(AnnotationKind.HIGHLIGHT, AnnotationKind.NOTE, AnnotationKind.BOOKMARK).forEach { kind ->
            val list = grouped[kind].orEmpty()
            if (list.isEmpty()) return@forEach
            append("<h2>").append(kind.label).append("s</h2>")
            list.forEach { a ->
                append("<div class=\"ann\" style=\"border-color:").append(htmlEscape(a.colorHex)).append("\">")
                if (a.selectedText.isNotBlank()) {
                    append("<div class=\"quote\">“").append(htmlEscape(a.selectedText)).append("”</div>")
                }
                if (a.note.isNotBlank()) {
                    append("<div class=\"note\">").append(htmlEscape(a.note)).append("</div>")
                }
                val tags = runCatching {
                    val arr = JSONArray(a.tagsJson)
                    buildList { for (i in 0 until arr.length()) arr.optString(i)?.takeIf { it.isNotBlank() }?.let(::add) }
                }.getOrDefault(emptyList())
                if (tags.isNotEmpty()) {
                    append("<div class=\"tags\">")
                    tags.forEach { append("<span class=\"tag\">").append(htmlEscape(it)).append("</span>") }
                    append("</div>")
                }
                append("<div class=\"footer\">")
                a.chapterId?.takeIf { it.isNotBlank() }?.let { append(htmlEscape(it)).append(": ") }
                append(DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(a.createdAt)))
                append("</div></div>")
            }
        }
        append("</body></html>")
    }

    private fun htmlEscape(s: String): String = s
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")

    private fun w3cAnnotations(
        annotations: List<ReaderAnnotation>,
        bookTitle: String?,
        bookAuthor: String?,
    ): String {
        val items = JSONArray()
        annotations.filter { it.deletedAt == null }.sortedBy { it.createdAt }.forEach { a ->
            val kind = AnnotationKind.parse(a.kind)
            val style = AnnotationStyle.parse(a.style)

            val body = JSONObject().apply {
                put("type", "TextualBody")
                put("value", a.note)
                put("format", "text/markdown")

                put("color", colorNameForHex(a.colorHex))
                put("highlight", w3cHighlightFor(kind, style))

                runCatching {
                    val tagArr = JSONArray(a.tagsJson)
                    if (tagArr.length() > 0) put("tag", tagArr.optString(0))
                }
            }

            val selectors = JSONArray()
            a.cssSelector?.let { css ->
                selectors.put(JSONObject().apply {
                    put("type", "CssSelector")
                    put("value", css)
                })
            }
            if (!a.textQuoteExact.isNullOrBlank()) {
                selectors.put(JSONObject().apply {
                    put("type", "TextQuoteSelector")
                    put("exact", a.textQuoteExact)
                    a.textQuotePrefix?.let { put("prefix", it) }
                    a.textQuoteSuffix?.let { put("suffix", it) }
                })
            }
            a.progression?.let { p ->
                selectors.put(JSONObject().apply {
                    put("type", "ProgressionSelector")
                    put("value", p)
                })
            }
            a.cfi?.let { cfi ->
                selectors.put(JSONObject().apply {
                    put("type", "FragmentSelector")
                    put("conformsTo", "http://www.idpf.org/epub/linking/cfi/")
                    put("value", "epubcfi($cfi)")
                })
            }

            val sourceHref = a.locatorJson?.let { runCatching { JSONObject(it).optString("href") }.getOrNull() }
                ?.takeIf { it.isNotBlank() }
            val target = JSONObject().apply {
                sourceHref?.let { put("source", it) }
                if (!a.chapterId.isNullOrBlank()) {
                    put("meta", JSONObject().apply { put("chapter", a.chapterId) })
                }
                if (selectors.length() > 0) put("selector", if (selectors.length() == 1) selectors.get(0) else selectors)
            }

            items.put(JSONObject().apply {
                put("@context", "http://www.w3.org/ns/anno.jsonld")
                put("id", "urn:uuid:${a.id}")
                put("type", "Annotation")
                put("created", iso8601(a.createdAt))
                put("modified", iso8601(a.updatedAt))
                put("body", body)
                put("target", target)
                put("motivation", if (kind == AnnotationKind.BOOKMARK) "bookmarking" else "highlighting")
            })
        }

        val set = JSONObject().apply {
            put("@context", "http://www.w3.org/ns/anno.jsonld")
            put("type", "AnnotationSet")
            put("generated", iso8601(System.currentTimeMillis()))
            put("generator", JSONObject().apply {
                put("type", "Software")
                put("name", "Enve Book Player (Android)")
                put("homepage", "https://envemedia.com")
            })
            if (!bookTitle.isNullOrBlank() || !bookAuthor.isNullOrBlank()) {
                put("about", JSONObject().apply {
                    put("dc:format", "application/epub+zip")
                    bookTitle?.let { put("dc:title", it) }
                    bookAuthor?.let { put("dc:creator", it) }
                })
            }
            put("items", items)
        }
        return set.toString(2)
    }

    private fun colorNameForHex(hex: String): String = when (hex.uppercase()) {
        "#FFF59D" -> "yellow"
        "#A5D6A7" -> "green"
        "#90CAF9" -> "blue"
        "#F8BBD0" -> "pink"
        "#FFCC80" -> "orange"
        "#CE93D8" -> "purple"
        else      -> hex
    }

    private fun w3cHighlightFor(kind: AnnotationKind, style: AnnotationStyle): String =
        if (kind == AnnotationKind.BOOKMARK) "bookmark"
        else when (style) {
            AnnotationStyle.HIGHLIGHT     -> "solid"
            AnnotationStyle.UNDERLINE     -> "underline"
            AnnotationStyle.STRIKETHROUGH -> "strikethrough"
            AnnotationStyle.SQUIGGLY -> "outline"
            AnnotationStyle.NONE          -> "solid"
        }

    private val iso8601Format: SimpleDateFormat by lazy {
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
    }
    private fun iso8601(ms: Long): String = iso8601Format.format(Date(ms))
}
