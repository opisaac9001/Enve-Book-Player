package com.enve.app.data.export

import com.enve.app.data.repository.AnnotationRepository
import com.enve.app.data.repository.LocatorAnchors
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.ReaderAnnotation
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AnnotationImporter @Inject constructor(
    private val annotationRepo: AnnotationRepository,
) {
    data class Parsed(
        val candidate: ReaderAnnotation,
        val anchors: LocatorAnchors,
        val verdict: Verdict,
        val existingRow: ReaderAnnotation?,
    )

    enum class Verdict { NEW, UNCHANGED, INCOMING_NEWER, INCOMING_OLDER }

    enum class Strategy {

        MERGE_NEWER,

        ADDITIVE,

        OVERWRITE,
    }

    suspend fun parse(bookId: String, fileContent: String): List<Parsed> {
        val rows: List<ReaderAnnotation> = when {
            fileContent.trimStart().startsWith("[") -> parseEnveJsonArray(bookId, fileContent)
            else -> parseW3cAnnotationSet(bookId, fileContent)
        }
        val byId = rows.associateBy { it.id }
        val existing = HashMap<String, ReaderAnnotation>(byId.size)
        for (id in byId.keys) annotationRepo.byId(id)?.let { existing[id] = it }
        return rows.map { row ->
            val local = existing[row.id]
            val verdict = when {
                local == null                          -> Verdict.NEW
                local.updatedAt == row.updatedAt       -> Verdict.UNCHANGED
                row.updatedAt   >  local.updatedAt     -> Verdict.INCOMING_NEWER
                else                                   -> Verdict.INCOMING_OLDER
            }
            Parsed(
                candidate = row,
                anchors = LocatorAnchors(
                    cfi              = row.cfi,
                    cssSelector      = row.cssSelector,
                    textQuoteExact   = row.textQuoteExact,
                    textQuotePrefix  = row.textQuotePrefix,
                    textQuoteSuffix  = row.textQuoteSuffix,
                    progression      = row.progression,
                    totalProgression = row.totalProgression,
                ),
                verdict = verdict,
                existingRow = local,
            )
        }
    }

    suspend fun commit(parsed: List<Parsed>, strategy: Strategy): Int {
        val toApply = parsed.filter { p ->
            when (strategy) {
                Strategy.ADDITIVE     -> p.verdict == Verdict.NEW
                Strategy.MERGE_NEWER  -> p.verdict == Verdict.NEW || p.verdict == Verdict.INCOMING_NEWER
                Strategy.OVERWRITE    -> p.verdict != Verdict.UNCHANGED
            }
        }
        if (toApply.isEmpty()) return 0

        annotationRepo.applyRemote(toApply.map { it.candidate.copy(syncDirty = false) })
        return toApply.size
    }

    private fun parseW3cAnnotationSet(bookId: String, content: String): List<ReaderAnnotation> {
        val root = runCatching { JSONObject(content) }.getOrElse { return emptyList() }
        val items = root.optJSONArray("items") ?: return emptyList()
        val out = ArrayList<ReaderAnnotation>(items.length())
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            out += parseW3cAnnotation(bookId, item) ?: continue
        }
        return out
    }

    private fun parseW3cAnnotation(bookId: String, item: JSONObject): ReaderAnnotation? {
        val id = item.optString("id").removePrefix("urn:uuid:").takeIf { it.isNotBlank() }
            ?: UUID.randomUUID().toString()
        val created  = parseIso8601(item.optString("created"))  ?: System.currentTimeMillis()
        val modified = parseIso8601(item.optString("modified")) ?: created

        val body  = item.optJSONObject("body") ?: JSONObject()
        val note  = body.optString("value", "")
        val color = body.optString("color").let { name -> hexForColorName(name) ?: name.takeIf { it.startsWith("#") } } ?: "#FFF59D"
        val tag   = body.optString("tag", "").takeIf { it.isNotBlank() }
        val tagsJson = if (tag != null) JSONArray().put(tag).toString() else "[]"

        val motivation = item.optString("motivation")
        val highlight  = body.optString("highlight")
        val kind = when {
            motivation == "bookmarking" || highlight == "bookmark" -> AnnotationKind.BOOKMARK
            note.isNotBlank() && (highlight.isBlank() || highlight == "solid") &&
                bodyHasNoQuote(item) -> AnnotationKind.NOTE
            else -> AnnotationKind.HIGHLIGHT
        }
        val style = when (highlight) {
            "underline"     -> AnnotationStyle.UNDERLINE
            "strikethrough" -> AnnotationStyle.STRIKETHROUGH
            "outline"       -> AnnotationStyle.SQUIGGLY
            "bookmark"      -> AnnotationStyle.NONE
            else            -> AnnotationStyle.HIGHLIGHT
        }

        val target = item.optJSONObject("target") ?: JSONObject()
        val sourceHref = target.optString("source").takeIf { it.isNotBlank() }
        val chapter    = target.optJSONObject("meta")?.optString("chapter")?.takeIf { it.isNotBlank() }
        val selectors  = readSelectors(target)

        val locatorJson = sourceHref?.let { href ->
            JSONObject().apply {
                put("href", href)
                put("type", "application/xhtml+xml")
                val locations = JSONObject().apply {
                    selectors.cfi?.let { put("fragments", JSONArray().put("epubcfi($it)")) }
                    selectors.cssSelector?.let { put("cssSelector", it) }
                    selectors.progression?.let { put("progression", it) }
                    selectors.totalProgression?.let { put("totalProgression", it) }
                }
                if (locations.length() > 0) put("locations", locations)
                selectors.textQuoteExact?.let { exact ->
                    put("text", JSONObject().apply { put("highlight", exact) })
                }
            }.toString()
        }

        return ReaderAnnotation(
            id = id,
            bookId = bookId,
            kind = kind.name,
            media = AnnotationMedia.EPUB.name,
            style = style.name,
            colorHex = color,
            locatorJson = locatorJson,
            chapterId = chapter,
            selectedText = selectors.textQuoteExact.orEmpty(),
            note = note,
            tagsJson = tagsJson,
            createdAt = created,
            updatedAt = modified,
            providerSource = "import",
            syncDirty = false,
            cfi = selectors.cfi,
            cssSelector = selectors.cssSelector,
            textQuoteExact = selectors.textQuoteExact,
            textQuotePrefix = selectors.textQuotePrefix,
            textQuoteSuffix = selectors.textQuoteSuffix,
            progression = selectors.progression,
            totalProgression = selectors.totalProgression,
        )
    }

    private fun bodyHasNoQuote(item: JSONObject): Boolean {
        val sels = readSelectors(item.optJSONObject("target") ?: return true)
        return sels.textQuoteExact.isNullOrBlank()
    }

    private data class ParsedSelectors(
        val cfi: String? = null,
        val cssSelector: String? = null,
        val textQuoteExact: String? = null,
        val textQuotePrefix: String? = null,
        val textQuoteSuffix: String? = null,
        val progression: Double? = null,
        val totalProgression: Double? = null,
    )

    private fun readSelectors(target: JSONObject): ParsedSelectors {
        var out = ParsedSelectors()
        val raw = target.opt("selector") ?: return out
        val arr: JSONArray = when (raw) {
            is JSONArray  -> raw
            is JSONObject -> JSONArray().put(raw)
            else          -> return out
        }
        for (i in 0 until arr.length()) {
            val sel = arr.optJSONObject(i) ?: continue
            when (sel.optString("type")) {
                "CssSelector"      -> out = out.copy(cssSelector = sel.optString("value").takeIf { it.isNotBlank() })
                "TextQuoteSelector" -> out = out.copy(
                    textQuoteExact  = sel.optString("exact").takeIf { it.isNotBlank() },
                    textQuotePrefix = sel.optString("prefix").takeIf { it.isNotBlank() },
                    textQuoteSuffix = sel.optString("suffix").takeIf { it.isNotBlank() },
                )
                "ProgressionSelector" -> out = out.copy(progression = sel.optDouble("value").takeIf { !it.isNaN() })
                "FragmentSelector"    -> {

                    val v = sel.optString("value")
                    if (v.startsWith("epubcfi(")) {
                        out = out.copy(cfi = v.removePrefix("epubcfi(").removeSuffix(")"))
                    }
                }
                "CfiSelector" -> out = out.copy(cfi = sel.optString("value").takeIf { it.isNotBlank() })
            }
        }
        return out
    }

    private fun parseEnveJsonArray(bookId: String, content: String): List<ReaderAnnotation> {
        val arr = runCatching { JSONArray(content) }.getOrElse { return emptyList() }
        val out = ArrayList<ReaderAnnotation>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val id = o.optString("id").takeIf { it.isNotBlank() } ?: UUID.randomUUID().toString()
            out += ReaderAnnotation(
                id = id,
                bookId = o.optString("bookId").takeIf { it.isNotBlank() } ?: bookId,
                kind = o.optString("kind", AnnotationKind.HIGHLIGHT.name),
                media = o.optString("media", AnnotationMedia.EPUB.name),
                style = o.optString("style", AnnotationStyle.HIGHLIGHT.name),
                colorHex = o.optString("colorHex", "#FFF59D"),
                locatorJson = o.optString("locatorJson").takeIf { it.isNotBlank() },
                chapterId   = o.optString("chapterId").takeIf { it.isNotBlank() },
                selectedText = o.optString("selectedText", ""),
                note         = o.optString("note", ""),
                tagsJson     = (o.opt("tags") as? JSONArray)?.toString() ?: "[]",
                createdAt    = o.optLong("createdAt", System.currentTimeMillis()),
                updatedAt    = o.optLong("updatedAt", System.currentTimeMillis()),
                providerSource = "import",
                syncDirty = false,
            )
        }
        return out
    }

    private fun hexForColorName(name: String): String? = when (name.lowercase()) {
        "yellow" -> "#FFF59D"
        "green"  -> "#A5D6A7"
        "blue"   -> "#90CAF9"
        "pink"   -> "#F8BBD0"
        "orange" -> "#FFCC80"
        "purple" -> "#CE93D8"
        else     -> null
    }

    private val iso8601Format: SimpleDateFormat by lazy {
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
    }
    private fun parseIso8601(s: String?): Long? {
        if (s.isNullOrBlank()) return null
        return runCatching { iso8601Format.parse(s)?.time }.getOrNull()
    }
}
