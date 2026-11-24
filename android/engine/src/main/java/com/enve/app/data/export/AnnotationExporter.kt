package com.enve.app.data.export

import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.ReaderAnnotation
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import org.json.JSONArray
import org.json.JSONObject
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.roundToInt

data class AnnotationExportBook(
    val title: String?,
    val author: String?,
    val annotations: List<ReaderAnnotation>,
)

object AnnotationExporter {

    enum class Format { MARKDOWN, JSON, PLAIN_TEXT, CSV, HTML, W3C_ANNOTATIONS }

    fun export(
        annotations: List<ReaderAnnotation>,
        bookTitle: String? = null,
        bookAuthor: String? = null,
        format: Format,
    ): String = export(listOf(AnnotationExportBook(bookTitle, bookAuthor, annotations)), format)

    fun export(books: List<AnnotationExportBook>, format: Format): String {
        val visible = books.map { book ->
            book.copy(annotations = book.annotations.filter { it.deletedAt == null }.sortedBy { it.createdAt })
        }
        return when (format) {
            Format.MARKDOWN        -> markdown(visible)
            Format.JSON            -> json(visible)
            Format.PLAIN_TEXT      -> plainText(visible)
            Format.CSV             -> csv(visible)
            Format.HTML            -> html(visible)
            Format.W3C_ANNOTATIONS -> w3cAnnotations(visible)
        }
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

    internal val kindOrder = listOf(AnnotationKind.HIGHLIGHT, AnnotationKind.NOTE, AnnotationKind.BOOKMARK)

    internal fun tags(annotation: ReaderAnnotation): List<String> = try {
        Json.parseToJsonElement(annotation.tagsJson).jsonArray.mapNotNull { element ->
            (element as? JsonPrimitive)?.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }
        }
    } catch (_: IllegalArgumentException) {
        emptyList()
    }

    internal fun locationLabel(annotation: ReaderAnnotation): String? = when (AnnotationMedia.parse(annotation.media)) {
        AnnotationMedia.PDF       -> annotation.pdfPage?.let { "Page ${it + 1}" }
        AnnotationMedia.CBZ       -> annotation.cbzPage?.let { "Page ${it + 1}" }
        AnnotationMedia.AUDIOBOOK -> annotation.audioPositionMs?.let(::timeOffset)
        AnnotationMedia.EPUB      -> (annotation.totalProgression ?: annotation.progression)
            ?.let { "${(it * 100.0).roundToInt().coerceIn(0, 100)}%" }
    }

    internal fun metaParts(annotation: ReaderAnnotation): List<String> = buildList {
        annotation.chapterId?.takeIf { it.isNotBlank() }?.let { add(singleLine(it)) }
        locationLabel(annotation)?.let(::add)
        add(DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(annotation.createdAt)))
    }

    internal fun singleLine(value: String): String = value.replace(Regex("\\s*[\\r\\n]+\\s*"), " ").trim()

    private fun normalizedNewlines(value: String): String = value.replace("\r\n", "\n").replace('\r', '\n')

    private fun timeOffset(ms: Long): String {
        val total = ms / 1000
        val hours = total / 3600
        val minutes = (total % 3600) / 60
        val seconds = total % 60
        return if (hours > 0) "%d:%02d:%02d".format(Locale.US, hours, minutes, seconds)
        else "%d:%02d".format(Locale.US, minutes, seconds)
    }

    private fun markdown(books: List<AnnotationExportBook>): String =
        books.joinToString("\n\n") { markdownBook(it).trimEnd() }.trimEnd()

    private fun markdownBook(book: AnnotationExportBook): String = buildString {
        if (!book.title.isNullOrBlank()) {
            append("# ").append(singleLine(book.title)).append("\n")
            if (!book.author.isNullOrBlank()) append("*by ").append(singleLine(book.author)).append("*\n")
            append("\n")
        }
        val grouped = book.annotations.groupBy { AnnotationKind.parse(it.kind) }
        kindOrder.forEach { kind ->
            val list = grouped[kind].orEmpty()
            if (list.isEmpty()) return@forEach
            append("## ").append(kind.label).append("s\n\n")
            list.forEach { a ->
                if (a.selectedText.isNotBlank()) {
                    append("> ")
                    append(normalizedNewlines(a.selectedText).replace("\n", "\n> "))
                    append("\n\n")
                }
                if (a.note.isNotBlank()) {
                    append(normalizedNewlines(a.note)).append("\n\n")
                }
                val tags = tags(a)
                if (tags.isNotEmpty()) {
                    append(tags.joinToString(" ") { "#" + it.replace(Regex("\\s+"), "-") }).append("\n\n")
                }
                append("- ").append(metaParts(a).joinToString(", ")).append("\n\n")
                append("---\n\n")
            }
        }
    }

    private fun json(books: List<AnnotationExportBook>): String {
        val arr = JSONArray()
        books.forEach { book ->
            book.annotations.forEach { a ->
                arr.put(JSONObject().apply {
                    put("id", a.id)
                    put("bookId", a.bookId)
                    book.title?.takeIf { it.isNotBlank() }?.let { put("bookTitle", it) }
                    book.author?.takeIf { it.isNotBlank() }?.let { put("bookAuthor", it) }
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
                    put("tags", JSONArray(tags(a)))
                    put("createdAt", a.createdAt)
                    put("updatedAt", a.updatedAt)
                })
            }
        }
        return arr.toString(2)
    }

    private fun plainText(books: List<AnnotationExportBook>): String {
        val titled = books.size > 1
        return books.joinToString("\n\n\n") { book ->
            val entries = book.annotations.joinToString("\n\n") { a ->
                buildString {
                    if (a.selectedText.isNotBlank()) append(a.selectedText)
                    if (a.note.isNotBlank()) {
                        if (isNotEmpty()) append("\n  ")
                        append(a.note)
                    }
                }.ifBlank { "[empty annotation]" }
            }
            val header = listOfNotNull(
                book.title?.takeIf { it.isNotBlank() }?.let(::singleLine),
                book.author?.takeIf { it.isNotBlank() }?.let(::singleLine),
            ).joinToString(" by ")
            if (titled && header.isNotEmpty()) "$header\n\n$entries" else entries
        }
    }

    private fun csv(books: List<AnnotationExportBook>): String = buildString {
        val cols = listOf(
            "id", "kind", "style", "colorHex", "chapter", "selectedText", "note",
            "tags", "createdAtIso", "updatedAtIso", "cfi", "totalProgression",
            "bookTitle", "bookAuthor", "location",
        )
        append(cols.joinToString(",") { csvField(it) }).append("\n")
        books.forEach { book ->
            book.annotations.forEach { a ->
                val row = listOf(
                    a.id, a.kind, a.style, a.colorHex, a.chapterId.orEmpty(),
                    a.selectedText, a.note, tags(a).joinToString("; "),
                    iso8601(a.createdAt), iso8601(a.updatedAt),
                    a.cfi.orEmpty(), a.totalProgression?.toString().orEmpty(),
                    book.title.orEmpty(), book.author.orEmpty(), locationLabel(a).orEmpty(),
                )
                append(row.joinToString(",") { csvField(it) }).append("\n")
            }
        }
    }

    internal fun csvField(v: String): String {
        val guarded = if (v.isNotEmpty() && v[0] in CSV_FORMULA_PREFIXES) "'$v" else v
        return "\"" + guarded.replace("\"", "\"\"") + "\""
    }

    private val CSV_FORMULA_PREFIXES = charArrayOf('=', '+', '-', '@', '\t', '\r')

    private fun html(books: List<AnnotationExportBook>): String = buildString {
        val documentTitle = books.singleOrNull()?.title?.takeIf { it.isNotBlank() } ?: "Annotations"
        append("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">")
        append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
        append("<title>").append(htmlEscape(documentTitle)).append("</title>")
        append("<style>")
        append("body{font-family:-apple-system,system-ui,sans-serif;max-width:42rem;margin:2rem auto;padding:0 1rem;color:#222;line-height:1.5}")
        append("h1{font-size:1.6rem;margin-bottom:.2rem}h2{margin-top:2rem;border-bottom:1px solid #ddd;padding-bottom:.3rem}")
        append(".meta{color:#888;font-size:.85rem;margin-bottom:1.5rem}")
        append(".ann{margin:1.4rem 0;padding:.8rem 1rem;border-left:4px solid;border-radius:4px;background:#fafafa}")
        append(".quote{font-style:italic;color:#444;white-space:pre-wrap}.note{margin-top:.5rem;white-space:pre-wrap}")
        append(".tags{margin-top:.4rem}.tag{display:inline-block;background:#eee;border-radius:4px;padding:1px 6px;font-size:.8rem;margin-right:.3rem}")
        append(".footer{color:#999;font-size:.8rem;margin-top:.6rem}")
        append("section+section{margin-top:3rem}")
        append("</style></head><body>")
        books.forEach { book ->
            if (books.size > 1) append("<section>")
            append("<h1>").append(htmlEscape(book.title?.takeIf { it.isNotBlank() } ?: "Annotations")).append("</h1>")
            if (!book.author.isNullOrBlank()) append("<div class=\"meta\">by ").append(htmlEscape(book.author)).append("</div>")
            val grouped = book.annotations.groupBy { AnnotationKind.parse(it.kind) }
            kindOrder.forEach { kind ->
                val list = grouped[kind].orEmpty()
                if (list.isEmpty()) return@forEach
                append("<h2>").append(kind.label).append("s</h2>")
                list.forEach { a ->
                    append("<div class=\"ann\" style=\"border-color:").append(cssColor(a.colorHex)).append("\">")
                    if (a.selectedText.isNotBlank()) {
                        append("<div class=\"quote\">“").append(htmlEscape(a.selectedText)).append("”</div>")
                    }
                    if (a.note.isNotBlank()) {
                        append("<div class=\"note\">").append(htmlEscape(a.note)).append("</div>")
                    }
                    val tags = tags(a)
                    if (tags.isNotEmpty()) {
                        append("<div class=\"tags\">")
                        tags.forEach { append("<span class=\"tag\">").append(htmlEscape(it)).append("</span>") }
                        append("</div>")
                    }
                    append("<div class=\"footer\">")
                    append(htmlEscape(metaParts(a).joinToString(" · ")))
                    append("</div></div>")
                }
            }
            if (books.size > 1) append("</section>")
        }
        append("</body></html>")
    }

    internal fun htmlEscape(s: String): String = s
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&#39;")

    internal fun cssColor(hex: String): String =
        hex.trim().takeIf { CSS_HEX.matches(it) } ?: DEFAULT_COLOR

    private val CSS_HEX = Regex("#(?:[0-9A-Fa-f]{3}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})")
    private const val DEFAULT_COLOR = "#FFF59D"

    private fun w3cAnnotations(books: List<AnnotationExportBook>): String {
        val items = JSONArray()
        val multiple = books.size > 1
        books.forEach { book ->
            book.annotations.forEach { a ->
                items.put(w3cAnnotation(a, book.takeIf { multiple }))
            }
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
            val single = books.singleOrNull()
            if (single != null && (!single.title.isNullOrBlank() || !single.author.isNullOrBlank())) {
                put("about", JSONObject().apply {
                    put("dc:format", "application/epub+zip")
                    single.title?.let { put("dc:title", it) }
                    single.author?.let { put("dc:creator", it) }
                })
            }
            put("items", items)
        }
        return set.toString(2)
    }

    private fun w3cAnnotation(a: ReaderAnnotation, book: AnnotationExportBook?): JSONObject {
        val kind = AnnotationKind.parse(a.kind)
        val style = AnnotationStyle.parse(a.style)

        val body = JSONObject().apply {
            put("type", "TextualBody")
            put("value", a.note)
            put("format", "text/markdown")
            put("color", colorNameForHex(a.colorHex))
            put("highlight", w3cHighlightFor(kind, style))
            tags(a).firstOrNull()?.let { put("tag", it) }
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
            val chapter = a.chapterId?.takeIf { it.isNotBlank() }
            if (chapter != null || book != null) {
                put("meta", JSONObject().apply {
                    chapter?.let { put("chapter", it) }
                    book?.title?.takeIf { it.isNotBlank() }?.let { put("dc:title", it) }
                    book?.author?.takeIf { it.isNotBlank() }?.let { put("dc:creator", it) }
                })
            }
            if (selectors.length() > 0) put("selector", if (selectors.length() == 1) selectors.get(0) else selectors)
        }

        return JSONObject().apply {
            put("@context", "http://www.w3.org/ns/anno.jsonld")
            put("id", "urn:uuid:${a.id}")
            put("type", "Annotation")
            put("created", iso8601(a.createdAt))
            put("modified", iso8601(a.updatedAt))
            put("body", body)
            put("target", target)
            put("motivation", if (kind == AnnotationKind.BOOKMARK) "bookmarking" else "highlighting")
        }
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
            AnnotationStyle.SQUIGGLY      -> "outline"
            AnnotationStyle.NONE          -> "solid"
        }

    private fun iso8601(ms: Long): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.format(Date(ms))
}
