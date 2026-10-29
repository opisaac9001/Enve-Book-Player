package com.enve.core.listeningposition

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.reader.EpubBridgeCheckpointCodec
import java.net.URLDecoder
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.text.Normalizer
import kotlin.math.roundToLong
import java.util.Locale
import kotlinx.serialization.json.*

class ListeningPositionPayloadException(val reason: String) : IllegalArgumentException(reason)

data class SharedReadingLocation(
    val format: String,
    val progressionUnits: Long,
    val href: String? = null,
    val resourceProgressionUnits: Long? = null,
    val page: Int? = null,
    val pageCount: Int? = null,
    val epubCfi: String? = null,
    val readiumLocatorJson: String? = null,
) {
    init {
        require(format.matches(Regex("[a-z0-9]{1,16}")))
        require(progressionUnits in 0..1_000_000L)
        require((href == null) == (resourceProgressionUnits == null))
        require(href == null || validHref(href))
        require(resourceProgressionUnits == null || resourceProgressionUnits in 0..1_000_000L)
        require(page == null || format in setOf("pdf", "comic"))
        require(href == null || format !in setOf("pdf", "comic"))
        require((epubCfi == null && readiumLocatorJson == null) || format !in setOf("pdf", "comic"))
        require(epubCfi == null || SharedReadiumLocator.validCfi(epubCfi))
        require(readiumLocatorJson == null || SharedReadiumLocator.sanitize(readiumLocatorJson) == readiumLocatorJson)
        require(href == null || readiumLocatorJson == null ||
            Json.parseToJsonElement(readiumLocatorJson).jsonObject["href"]?.jsonPrimitive?.content == href)
        require(page == null || page in 1..1_000_000)
        require(pageCount == null || page != null && pageCount in 1..1_000_000 && page <= pageCount)
    }

    val progression: Double get() = progressionUnits / 1_000_000.0

    fun progressionFor(book: Book): Float =
        if (page != null && format == format(book) && (book.pageCount ?: 0) > 0) page.toFloat() / book.pageCount!!
        else progression.toFloat()

    fun locatorFor(book: Book): String? {
        val targetFormat = format(book)
        val sameFormat = format == targetFormat
        if (targetFormat in setOf("pdf", "comic")) {
            val nativePage = page?.takeIf { sameFormat } ?: book.pageCount?.takeIf { it > 0 }?.let { (progression * it).roundToLong().coerceIn(1, it.toLong()).toInt() }
            return buildJsonObject {
                nativePage?.let { put("page", it) }
                put("enveSharedPosition", true)
            }.toString()
        }
        val native = readiumLocatorJson?.takeIf { sameFormat }?.let { Json.parseToJsonElement(it).jsonObject }
        val locations = (native?.get("locations") as? JsonObject).orEmpty().toMutableMap()
        if (sameFormat && href != null && "progression" !in locations) locations["progression"] = JsonPrimitive(resourceProgressionUnits!! / 1_000_000.0)
        if (sameFormat && epubCfi != null) {
            locations["cfi"] = JsonPrimitive(epubCfi)
            locations["enveSourceEngine"] = JsonPrimitive("foliate")
        }
        locations["totalProgression"] = JsonPrimitive(progression)
        return buildJsonObject {
            native?.forEach { (key, value) -> put(key, value) }
            if (sameFormat && href != null) {
                put("href", href)
                put("type", "application/xhtml+xml")
            }
            put("locations", JsonObject(locations))
            put("enveSharedPosition", true)
        }.toString()
    }

    companion object {
        fun isSharedPosition(locator: String?): Boolean = locator?.let {
            runCatching { ((Json.parseToJsonElement(it) as? JsonObject)?.get("enveSharedPosition") as? JsonPrimitive)?.booleanOrNull == true }.getOrDefault(false)
        } ?: false

        fun format(book: Book): String = when (val format = book.primaryFileType?.lowercase(Locale.ROOT)) {
            "cbz", "cbr", "cbx", "cb7", "cbt", "imagefolder" -> "comic"
            null -> "ebook"
            else -> format.takeIf { it.matches(Regex("[a-z0-9]{1,16}")) } ?: "ebook"
        }

        fun from(book: Book): SharedReadingLocation {
            val format = format(book)
            val paged = format in setOf("pdf", "comic")
            val native = if (paged) null else SharedReadiumLocator.fromSavedPosition(book.epubLocator)
            val cfi = if (paged) null else (EpubBridgeCheckpointCodec.cfi(book.epubLocator)
                ?: EpubBridgeCheckpointCodec.cfi(native))?.takeIf(SharedReadiumLocator::validCfi)
            val locator = (native ?: book.epubLocator)?.let { runCatching { Json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
            val locations = locator?.get("locations") as? JsonObject
            val progression = (book.epubProgress ?: book.readProgress).toDouble().takeIf { it.isFinite() }?.coerceIn(0.0, 1.0) ?: 0.0
            val href = if (format in setOf("pdf", "comic")) null
                else (locator?.get("href") as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf(::validHref)
            val offset = (locations?.get("progression") as? JsonPrimitive)?.doubleOrNull?.takeIf { it.isFinite() && it in 0.0..1.0 }
            val count = book.pageCount?.takeIf { it in 1..1_000_000 }
            val page = if (format in setOf("pdf", "comic")) {
                (locator?.get("page") as? JsonPrimitive)?.intOrNull
                    ?: book.epubLocator?.substringAfter("-page:", "")?.toIntOrNull()
                    ?: if (progression > 0 && count != null) (progression * count).roundToLong().toInt().coerceAtLeast(1) else null
            } else null
            val safePage = page?.takeIf { it in 1..1_000_000 && (count == null || it <= count) }
            return SharedReadingLocation(format, (progression * 1_000_000).roundToLong(),
                if (offset != null) href else null, if (href != null) offset?.let { (it * 1_000_000).roundToLong() } else null,
                safePage, if (safePage != null) count else null, cfi, native)
        }

        fun validHref(value: String): Boolean {
            fun forbidden(text: String): Boolean = text.codePoints().anyMatch { cp ->
                val type = Character.getType(cp)
                cp == 0x2028 || cp == 0x2029 || type == Character.CONTROL.toInt() || type == Character.SURROGATE.toInt() ||
                    type == Character.FORMAT.toInt()
            }
            if (value.isEmpty() || value.codePointCount(0, value.length) > 256 || Normalizer.normalize(value, Normalizer.Form.NFC) != value || forbidden(value) ||
                value.any { it in "\\:?#" } || value.startsWith('/')) return false
            val decoded = try {
                for (run in Regex("(?:%[0-9a-fA-F]{2})+").findAll(value)) {
                    val bytes = run.value.split('%').drop(1).map { it.toInt(16).toByte() }.toByteArray()
                    Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes))
                }
                URLDecoder.decode(value.replace("+", "%2B"), Charsets.UTF_8)
            } catch (_: IllegalArgumentException) { return false }
            catch (_: CharacterCodingException) { return false }
            return !decoded.startsWith('/') && !forbidden(decoded) && decoded.none { it in "\\:?#" } && decoded.split('/').none { it == ".." }
        }
    }
}

data class ListeningPositionPayload(
    val positionMilliseconds: Long,
    val durationMilliseconds: Long,
    val title: String,
    val authors: List<String> = emptyList(),
    val narrators: List<String> = emptyList(),
    val series: String? = null,
    val seriesSequence: String? = null,
    val asin: String? = null,
    val isbn: String? = null,
    val readingLocation: SharedReadingLocation? = null,
) {
    init {
        if (readingLocation == null) {
            validate(durationMilliseconds in 1..MAX_DURATION_MILLISECONDS, "dur")
            validate(positionMilliseconds in 0..durationMilliseconds, "pos")
        } else validate(positionMilliseconds == 0L && durationMilliseconds == 0L, "m")
        validate(validText(title, 160), "t")
        validate(authors.size <= 4 && authors.all { validText(it, 100) }, "a")
        validate(narrators.size <= 4 && narrators.all { validText(it, 100) }, "n")
        validate(series == null || validText(series, 120), "s")
        validate(seriesSequence == null || validText(seriesSequence, 16), "q")
        validate(asin == null || normalizedASIN(asin) == asin, "asin")
        validate(isbn == null || normalizedISBN(isbn) == isbn, "isbn")
    }

    fun encoded(): String {
        val fields = sortedMapOf<String, String>()
        if (authors.isNotEmpty()) fields["a"] = authors.joinToString(",", "[", "]", transform = ::quoted)
        asin?.let { fields["asin"] = quoted(it) }
        if (readingLocation == null) fields["dur"] = durationMilliseconds.toString()
        else {
            readingLocation.epubCfi?.let { fields["c"] = quoted(it) }
            readingLocation.readiumLocatorJson?.let { fields["l"] = quoted(it) }
            fields["f"] = quoted(readingLocation.format)
            fields["m"] = quoted("reading")
            fields["p"] = readingLocation.progressionUnits.toString()
            readingLocation.href?.let { fields["h"] = quoted(it) }
            readingLocation.resourceProgressionUnits?.let { fields["o"] = it.toString() }
            readingLocation.page?.let { fields["page"] = it.toString() }
            readingLocation.pageCount?.let { fields["pages"] = it.toString() }
        }
        isbn?.let { fields["isbn"] = quoted(it) }
        fields["k"] = quoted(KIND)
        if (narrators.isNotEmpty()) fields["n"] = narrators.joinToString(",", "[", "]", transform = ::quoted)
        if (readingLocation == null) fields["pos"] = positionMilliseconds.toString()
        seriesSequence?.let { fields["q"] = quoted(it) }
        series?.let { fields["s"] = quoted(it) }
        fields["t"] = quoted(title)
        fields["v"] = if (readingLocation == null) "1" else "2"
        return fields.entries.joinToString(",", "{", "}") { (key, value) -> "\"$key\":$value" }
    }

    companion object {
        const val KIND = "enve.position"
        const val MAX_ENCODED_BYTES = 2200
        const val MAX_DURATION_MILLISECONDS = 3_600_000_000L
        private val json = Json

        fun decode(text: String): ListeningPositionPayload {
            validate(text.length <= MAX_ENCODED_BYTES && text.toByteArray(Charsets.UTF_8).size <= MAX_ENCODED_BYTES, "tooLarge")
            val obj = try { json.parseToJsonElement(text) as? JsonObject }
                catch (_: IllegalArgumentException) { null }
                ?: throw ListeningPositionPayloadException("notListeningPosition")
            validate((obj["k"] as? JsonPrimitive)?.takeIf { it.isString }?.content == KIND, "notListeningPosition")
            val version = integer(obj["v"], "v")
            validate(version in 1..Int.MAX_VALUE.toLong(), "v")
            validate(version == 1L || version == 2L, "unsupportedVersion")
            fun string(key: String, required: Boolean = false): String? {
                val value = obj[key] ?: if (required) throw ListeningPositionPayloadException(key) else return null
                return (value as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: throw ListeningPositionPayloadException(key)
            }
            fun names(key: String): List<String> {
                val value = obj[key] ?: return emptyList()
                return (value as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: throw ListeningPositionPayloadException(key) } ?: throw ListeningPositionPayloadException(key)
            }
            val reading = if (version == 2L) {
                validate(string("m") == "reading" && "pos" !in obj && "dur" !in obj, "m")
                fun optionalInteger(key: String): Long? = if (key in obj) integer(obj[key], key) else null
                fun page(key: String): Int? = optionalInteger(key)?.also { validate(it in 1..1_000_000L, key) }?.toInt()
                try {
                    SharedReadingLocation(string("f", true)!!, integer(obj["p"], "p"), string("h"), optionalInteger("o"), page("page"), page("pages"),
                        string("c"), string("l")?.let(SharedReadiumLocator::sanitize))
                } catch (error: ListeningPositionPayloadException) { throw error }
                catch (_: IllegalArgumentException) { throw ListeningPositionPayloadException("location") }
            } else {
                validate(listOf("m", "f", "p", "h", "o", "page", "pages", "c", "l").none(obj::containsKey), "m")
                null
            }
            return ListeningPositionPayload(if (reading == null) integer(obj["pos"], "pos") else 0,
                if (reading == null) integer(obj["dur"], "dur") else 0,
                string("t", true)!!, names("a"), names("n"), string("s"), string("q"), string("asin"), string("isbn"), reading)
        }

        fun from(book: Book, positionMilliseconds: Long = book.currentTime.coerceIn(0, MAX_DURATION_MILLISECONDS / 1000) * 1000L, durationMilliseconds: Long = book.duration.takeIf { it in 1..MAX_DURATION_MILLISECONDS / 1000 }?.times(1000L) ?: 0L): ListeningPositionPayload? {
            val reading = if (book.mediaType == AppMediaType.EBOOK) SharedReadingLocation.from(book) else null
            if (reading == null && durationMilliseconds !in 1..MAX_DURATION_MILLISECONDS) return null
            val title = sanitized(book.title, 160) ?: return null
            fun people(names: List<String>) = names.mapNotNull { sanitized(it, 100) }
                .distinctBy { it.lowercase(Locale.ROOT) }.take(4)
            val series = book.seriesName?.let { sanitized(it, 120) }
            var payload = ListeningPositionPayload(if (reading == null) positionMilliseconds.coerceIn(0, durationMilliseconds) else 0,
                if (reading == null) durationMilliseconds else 0, title,
                people(listOfNotNull(book.author)), people(book.narrator.orEmpty().split(',', ';', '&')),
                series, if (series != null) book.seriesNumber?.let { sanitized(it, 16) } else null,
                isbn = book.isbn13?.let(::normalizedISBN), readingLocation = reading)
            while (payload.encoded().toByteArray(Charsets.UTF_8).size > MAX_ENCODED_BYTES) {
                payload = when {
                    payload.narrators.isNotEmpty() -> payload.copy(narrators = emptyList())
                    payload.series != null -> payload.copy(series = null, seriesSequence = null)
                    payload.authors.size > 1 -> payload.copy(authors = payload.authors.take(1))
                    payload.authors.isNotEmpty() -> payload.copy(authors = emptyList())
                    else -> return null
                }
            }
            return payload
        }

        fun normalizedASIN(value: String): String? = value.trim().uppercase(Locale.ROOT)
            .takeIf { it.matches(Regex("[A-Z0-9]{10}")) }

        fun normalizedISBN(value: String): String? = value.uppercase(Locale.ROOT).replace("-", "").replace(" ", "")
            .takeIf { it.matches(Regex("[0-9]{9}[0-9X]|97[89][0-9]{10}")) }

        private fun integer(value: JsonElement?, field: String): Long {
            val number = (value as? JsonPrimitive)?.takeUnless { it.isString }?.content?.toDoubleOrNull()
            validate(number != null && number.isFinite() && number == kotlin.math.floor(number) && kotlin.math.abs(number) <= 9_007_199_254_740_991.0, field)
            return number!!.toLong()
        }

        private fun quoted(value: String): String = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        private fun validate(valid: Boolean, field: String) { if (!valid) throw ListeningPositionPayloadException(field) }
        private fun validText(value: String, limit: Int): Boolean = sanitized(value, limit) == value

        private fun sanitized(value: String, limit: Int): String? {
            if (value.codePoints().anyMatch { it in 0xD800..0xDFFF }) return null
            val normalized = Normalizer.normalize(value, Normalizer.Form.NFC)
            val cleaned = StringBuilder()
            var space = false
            normalized.codePoints().forEach { cp ->
                val type = Character.getType(cp)
                val disallowed = cp == 0x2028 || cp == 0x2029 || type == Character.CONTROL.toInt() || type == Character.SURROGATE.toInt() ||
                    (type == Character.FORMAT.toInt() && cp != 0x200C && cp != 0x200D)
                if (disallowed || Character.isWhitespace(cp) || Character.isSpaceChar(cp)) {
                    if (cleaned.isNotEmpty()) space = true
                } else {
                    if (space) cleaned.append(' ')
                    space = false
                    cleaned.appendCodePoint(cp)
                }
            }
            if (cleaned.isEmpty()) return null
            val text = cleaned.toString()
            if (text.codePointCount(0, text.length) <= limit) return text
            val iterator = java.text.BreakIterator.getCharacterInstance(Locale.ROOT)
            iterator.setText(text)
            var end = iterator.first()
            var next = iterator.next()
            while (next != java.text.BreakIterator.DONE && text.codePointCount(0, next) <= limit) {
                end = next
                next = iterator.next()
            }
            return text.substring(0, end).trimEnd().takeIf { it.isNotEmpty() }
        }
    }
}
