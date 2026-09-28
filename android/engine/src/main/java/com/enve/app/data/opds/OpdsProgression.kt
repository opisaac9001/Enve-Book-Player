package com.enve.app.data.opds

import com.enve.core.data.util.stringLiteralOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.net.URLDecoder
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

const val OPDS_PROGRESSION_REL = "http://opds-spec.org/progression"
const val OPDS_PROGRESSION_MEDIA_TYPE = "application/opds-progression+json"

data class OpdsProgressionDevice(val id: String, val name: String)

sealed interface OpdsProgressionTarget {
    data object Resource : OpdsProgressionTarget

    data class Time(val seconds: Double) : OpdsProgressionTarget

    data class Page(val page: Int) : OpdsProgressionTarget

    data class Text(val directive: String) : OpdsProgressionTarget {
        val start: String?
            get() {
                val value = directive.removePrefix("text=").takeIf { it != directive } ?: return null
                val parts = value.split(',')
                return parts
                    .filterIndexed { index, part ->
                        val isPrefix = index == 0 && parts.size > 1 && part.endsWith('-')
                        val isSuffix = index == parts.lastIndex && parts.size > 1 && part.startsWith('-')
                        !isPrefix && !isSuffix
                    }
                    .firstOrNull()
                    ?.takeIf { it.isNotEmpty() }
                    ?.let(::percentDecode)
            }
    }

    data class Cfi(val cfi: String) : OpdsProgressionTarget

    data class Id(val id: String) : OpdsProgressionTarget

    data class Unknown(val fragment: String) : OpdsProgressionTarget
}

data class OpdsProgressionReference(
    val raw: String,
    val resource: String?,
    val target: OpdsProgressionTarget,
)

object OpdsProgressionReferences {

    fun parse(raw: String): OpdsProgressionReference {
        val hash = raw.indexOf('#')
        val resource = (if (hash < 0) raw else raw.take(hash)).takeIf { it.isNotEmpty() }
        val fragment = if (hash < 0) null else raw.substring(hash + 1)
        return OpdsProgressionReference(raw = raw, resource = resource, target = targetOf(fragment))
    }

    fun time(seconds: Double): OpdsProgressionReference =
        parse("#t=${formatSeconds(seconds.coerceAtLeast(0.0))}")

    fun page(page: Int): OpdsProgressionReference = parse("#page=$page")

    fun resource(path: String): OpdsProgressionReference = parse(path)

    fun id(resource: String?, id: String): OpdsProgressionReference =
        parse("${resource.orEmpty()}#${percentEncode(id, ID_SAFE)}")

    fun text(resource: String?, quote: String): OpdsProgressionReference =
        parse("${resource.orEmpty()}#:~:text=${percentEncode(quote)}")

    fun cfi(resource: String?, cfi: String): OpdsProgressionReference {
        val body = cfi.removePrefix("epubcfi(").removeSuffix(")")
        return parse("${resource.orEmpty()}#epubcfi(${percentEncode(body, CFI_SAFE)})")
    }

    private fun targetOf(fragment: String?): OpdsProgressionTarget = when {
        fragment.isNullOrEmpty() -> OpdsProgressionTarget.Resource
        fragment.startsWith("epubcfi(") && fragment.endsWith(")") ->
            OpdsProgressionTarget.Cfi("epubcfi(${percentDecode(fragment.removePrefix("epubcfi(").removeSuffix(")"))})")

        fragment.contains(":~:") -> OpdsProgressionTarget.Text(fragment.substringAfter(":~:"))
        fragment.startsWith("t=") -> timeTarget(fragment)
        fragment.startsWith("page=") -> pageTarget(fragment)
        !fragment.contains('=') && !fragment.contains(',') -> OpdsProgressionTarget.Id(percentDecode(fragment))
        else -> OpdsProgressionTarget.Unknown(fragment)
    }

    private fun timeTarget(fragment: String): OpdsProgressionTarget {
        val start = fragment.removePrefix("t=")
            .substringBefore('&')
            .removePrefix("npt:")
            .substringBefore(',')
        if (start.isEmpty()) return OpdsProgressionTarget.Time(0.0)
        val seconds = parseClock(start) ?: return OpdsProgressionTarget.Unknown(fragment)
        return OpdsProgressionTarget.Time(seconds)
    }

    private fun pageTarget(fragment: String): OpdsProgressionTarget {
        val page = fragment.removePrefix("page=").substringBefore('&').toIntOrNull()
        return page?.let(OpdsProgressionTarget::Page) ?: OpdsProgressionTarget.Unknown(fragment)
    }

    private fun parseClock(value: String): Double? {
        if (!value.contains(':')) return value.toDoubleOrNull()?.takeIf { it >= 0.0 }
        val parts = value.split(':')
        if (parts.size > 3) return null
        var total = 0.0
        for (part in parts) {
            val unit = part.toDoubleOrNull() ?: return null
            if (unit < 0.0) return null
            total = total * 60.0 + unit
        }
        return total
    }

    private fun formatSeconds(seconds: Double): String =
        String.format(Locale.ROOT, "%.3f", seconds).trimEnd('0').trimEnd('.')
}

data class OpdsProgressionDocument(
    val modified: String,
    val modifiedAtMs: Long,
    val device: OpdsProgressionDevice,
    val progression: Double,
    val title: String? = null,
    val references: List<OpdsProgressionReference> = emptyList(),
    val additionalMembers: JsonObject = JsonObject(emptyMap()),
) {
    val timeSeconds: Double?
        get() = references.firstNotNullOfOrNull { (it.target as? OpdsProgressionTarget.Time)?.seconds }

    val epubCfi: String?
        get() = references.firstNotNullOfOrNull { (it.target as? OpdsProgressionTarget.Cfi)?.cfi }

    val pdfPage: Int?
        get() = references.firstNotNullOfOrNull { (it.target as? OpdsProgressionTarget.Page)?.page }

    val textQuote: String?
        get() = references.firstNotNullOfOrNull { (it.target as? OpdsProgressionTarget.Text)?.start }

    val fragmentId: String?
        get() = references.firstNotNullOfOrNull { (it.target as? OpdsProgressionTarget.Id)?.id }

    val resourcePath: String?
        get() = references.firstNotNullOfOrNull { it.resource }

    val unhandledReferences: List<String>
        get() = references.filter { it.target is OpdsProgressionTarget.Unknown }.map { it.raw }

    companion object {
        fun at(
            modifiedAtMs: Long,
            device: OpdsProgressionDevice,
            progression: Double,
            title: String? = null,
            references: List<OpdsProgressionReference> = emptyList(),
            additionalMembers: JsonObject = JsonObject(emptyMap()),
        ): OpdsProgressionDocument = OpdsProgressionDocument(
            modified = DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(modifiedAtMs)),
            modifiedAtMs = modifiedAtMs,
            device = device,
            progression = progression.coerceIn(0.0, 1.0),
            title = title,
            references = references,
            additionalMembers = additionalMembers,
        )
    }
}

data class OpdsProblemDetails(val type: String, val title: String)

object OpdsProgressionCodec {

    private val json = Json { ignoreUnknownKeys = true }

    private val knownMembers = setOf("title", "modified", "device", "progression", "references")

    fun decode(payload: String?): OpdsProgressionDocument? {
        val root = objectOf(payload) ?: return null
        val modified = root["modified"].stringLiteralOrNull() ?: return null
        val modifiedAtMs = parseTimestamp(modified) ?: return null
        val device = root["device"] as? JsonObject ?: return null
        val deviceId = device["id"].stringLiteralOrNull()?.takeIf(::isUri) ?: return null
        val deviceName = device["name"].stringLiteralOrNull()?.takeIf { it.isNotBlank() } ?: return null
        val progression = root["progression"].numberOrNull()?.takeIf { it in 0.0..1.0 } ?: return null
        val title = when (val node = root["title"]) {
            null, JsonNull -> null
            else -> (node.stringLiteralOrNull() ?: return null).takeIf { it.isNotBlank() }
        }
        val references = when (val node = root["references"]) {
            null, JsonNull -> emptyList<OpdsProgressionReference>()
            is JsonArray -> node.map { element ->
                val raw = element.stringLiteralOrNull()?.takeIf(::isUriReference) ?: return null
                OpdsProgressionReferences.parse(raw)
            }

            else -> return null
        }
        return OpdsProgressionDocument(
            modified = modified,
            modifiedAtMs = modifiedAtMs,
            device = OpdsProgressionDevice(id = deviceId, name = deviceName),
            progression = progression,
            title = title,
            references = references,
            additionalMembers = JsonObject(root.filterKeys { it !in knownMembers }),
        )
    }

    fun encode(document: OpdsProgressionDocument): String = buildJsonObject {
        document.title?.takeIf { it.isNotBlank() }?.let { put("title", it) }
        put("modified", document.modified)
        put(
            "device",
            buildJsonObject {
                put("id", document.device.id)
                put("name", document.device.name)
            },
        )
        put("progression", document.progression)
        if (document.references.isNotEmpty()) {
            put("references", JsonArray(document.references.map { JsonPrimitive(it.raw) }))
        }
        document.additionalMembers.forEach { (key, value) -> put(key, value) }
    }.toString()

    fun decodeProblem(payload: String?): OpdsProblemDetails? {
        val root = objectOf(payload) ?: return null
        val type = root["type"].stringLiteralOrNull()?.takeIf { it.isNotBlank() } ?: return null
        val title = root["title"].stringLiteralOrNull()?.takeIf { it.isNotBlank() } ?: return null
        return OpdsProblemDetails(type = type, title = title)
    }

    private fun objectOf(payload: String?): JsonObject? {
        val text = payload?.trim()?.takeIf { it.startsWith("{") } ?: return null
        return runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull()
    }

    private fun parseTimestamp(value: String): Long? =
        runCatching { OffsetDateTime.parse(value.trim()).toInstant().toEpochMilli() }.getOrNull()

    private fun JsonElement?.numberOrNull(): Double? =
        (this as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toDoubleOrNull()
}

internal fun mergeProgressionReferences(
    generated: List<OpdsProgressionReference>,
    carried: List<String>,
): List<OpdsProgressionReference> {
    val seen = generated.mapTo(mutableSetOf()) { it.raw }
    return generated + carried.filter { seen.add(it) }.map(OpdsProgressionReferences::parse)
}

internal fun isUriReference(value: String): Boolean {
    if (value.isEmpty()) return false
    var index = 0
    while (index < value.length) {
        val char = value[index]
        if (char == '%') {
            if (index + 2 >= value.length) return false
            if (!value[index + 1].isUriHex() || !value[index + 2].isUriHex()) return false
            index += 2
        } else if (char !in URI_REFERENCE_SAFE) {
            return false
        }
        index++
    }
    return true
}

internal fun isUri(value: String): Boolean = URI_SCHEME.containsMatchIn(value) && isUriReference(value)

private val URI_SCHEME = Regex("^[A-Za-z][A-Za-z0-9+\\-.]*:")

private fun Char.isUriHex(): Boolean = this in "0123456789abcdefABCDEF"

private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~"
private const val ID_SAFE = "-:"
private const val CFI_SAFE = "-!\$&'*+,/:;=@"
private const val URI_REFERENCE_SAFE = UNRESERVED + "-" + ":/?#[]@!\$&'()*+,;="
private const val HEX = "0123456789ABCDEF"

internal fun percentEncode(value: String, extraSafe: String = ""): String = buildString {
    for (byte in value.toByteArray(Charsets.UTF_8)) {
        val code = byte.toInt() and 0xFF
        val char = code.toChar()
        if (char in UNRESERVED || (extraSafe.isNotEmpty() && char in extraSafe)) {
            append(char)
        } else {
            append('%').append(HEX[code shr 4]).append(HEX[code and 0x0F])
        }
    }
}

internal fun percentDecode(value: String): String =
    runCatching { URLDecoder.decode(value.replace("+", "%2B"), Charsets.UTF_8.name()) }.getOrDefault(value)
