package com.enve.core.listeningposition

import com.enve.core.reader.EpubBridgeCheckpointCodec
import java.math.BigDecimal
import kotlinx.serialization.json.*

internal object SharedReadiumLocator {
    fun validCfi(value: String): Boolean = value == value.trim() && value.toByteArray(Charsets.UTF_8).size <= 2048 &&
        EpubBridgeCheckpointCodec.isFullEpubCfi(value)

    fun fromSavedPosition(raw: String?): String? {
        if (raw == null) return null
        val checkpoint = EpubBridgeCheckpointCodec.decode(raw)
        val native = checkpoint?.nativeReadiumLocatorJson?.let(::parse)
        val portable = checkpoint?.let(EpubBridgeCheckpointCodec::toReadiumLocatorJson)?.let(::parse)
        val locator = if (checkpoint == null) parse(raw) else {
            val root = (native.orEmpty() + portable.orEmpty()).toMutableMap()
            val locations = ((native?.get("locations") as? JsonObject).orEmpty() +
                (portable?.get("locations") as? JsonObject).orEmpty()).toMutableMap()
            checkpoint.epubCfi?.takeIf(::validCfi)?.let {
                locations["cfi"] = JsonPrimitive(it)
                locations["enveSourceEngine"] = JsonPrimitive("foliate")
            }
            root["locations"] = JsonObject(locations)
            JsonObject(root)
        }
        return locator?.let { sanitize(it, strict = false) }
    }

    fun sanitize(raw: String): String = sanitize(parse(raw)
        ?: throw ListeningPositionPayloadException("l"), strict = true)
        ?: throw ListeningPositionPayloadException("l")

    private fun parse(raw: String): JsonObject? =
        runCatching { Json.parseToJsonElement(raw) as? JsonObject }.getOrNull()

    private fun sanitize(root: JsonObject, strict: Boolean): String? {
        fun invalid(): Nothing = throw ListeningPositionPayloadException("l")
        fun checked(value: JsonElement?, predicate: (JsonElement) -> Boolean): JsonElement? {
            if (value == null) return null
            if (predicate(value)) return value
            if (strict) invalid()
            return null
        }
        fun text(value: JsonElement?, allowControls: Boolean = false, maxScalars: Int? = null): JsonElement? = checked(value) {
            val primitive = it as? JsonPrimitive
            val string = primitive?.takeIf { it.isString }?.content
            string != null && string.toByteArray(Charsets.UTF_8).size <= 2048 &&
                string.codePoints().noneMatch { cp -> cp in 0xD800..0xDFFF || (!allowControls && Character.isISOControl(cp)) } &&
                (maxScalars == null || string.codePointCount(0, string.length) <= maxScalars)
        }
        fun number(value: JsonElement?, integer: Boolean, minimum: Double, maximum: Double): JsonElement? = checked(value) {
            val primitive = it as? JsonPrimitive
            val number = primitive?.takeUnless { it.isString }?.doubleOrNull
            number != null && number.isFinite() && number in minimum..maximum && (!integer || number == kotlin.math.floor(number))
        }
        fun point(value: JsonElement?): JsonObject? {
            val source = checked(value) { it is JsonObject } as? JsonObject ?: return null
            val selector = text(source["cssSelector"])?.takeIf { it.jsonPrimitive.content.isNotEmpty() }
            val index = number(source["textNodeIndex"], true, 0.0, 1_000_000_000.0)
            if (selector == null || index == null) {
                if (strict) invalid()
                return null
            }
            return buildJsonObject {
                put("cssSelector", selector)
                put("textNodeIndex", index)
                number(source["charOffset"], true, 0.0, 1_000_000_000.0)?.let { put("charOffset", it) }
            }
        }
        val href = checked(root["href"]) { it is JsonPrimitive && it.isString && SharedReadingLocation.validHref(it.content) }
        val type = checked(root["type"]) { it is JsonPrimitive && it.isString && it.content in setOf("application/xhtml+xml", "text/html") }
        val sourceLocations = checked(root["locations"]) { it is JsonObject } as? JsonObject
        if (href == null || (strict && (type == null || sourceLocations == null))) {
            if (strict) invalid()
            return null
        }
        val locations = buildJsonObject {
            for (key in listOf("progression", "totalProgression")) {
                number(sourceLocations?.get(key), false, 0.0, 1.0)?.let { put(key, it) }
            }
            number(sourceLocations?.get("position"), true, 1.0, 1_000_000_000.0)?.let { put("position", it) }
            checked(sourceLocations?.get("cfi")) { it is JsonPrimitive && it.isString && validCfi(it.content) }?.let { put("cfi", it) }
            for (key in listOf("partialCfi", "cssSelector")) {
                text(sourceLocations?.get(key))?.let { put(key, it) }
            }
            checked(sourceLocations?.get("enveSourceEngine")) {
                it is JsonPrimitive && it.isString && it.content in setOf("readium", "foliate")
            }?.let { put("enveSourceEngine", it) }
            val fragments = checked(sourceLocations?.get("fragments")) { it is JsonArray && it.size <= 32 } as? JsonArray
            fragments?.let { values ->
                val kept = values.mapNotNull { text(it, maxScalars = 512) }
                put("fragments", JsonArray(kept))
            }
            val range = checked(sourceLocations?.get("domRange")) { it is JsonObject } as? JsonObject
            range?.let {
                val start = point(it["start"])
                if (start == null && strict) invalid()
                if (start != null) put("domRange", buildJsonObject {
                    put("start", start)
                    point(it["end"])?.let { end -> put("end", end) }
                })
            }
        }
        return canonical(buildJsonObject {
            put("href", href)
            put("type", type ?: JsonPrimitive("application/xhtml+xml"))
            put("locations", locations)
            val sourceText = checked(root["text"]) { it is JsonObject } as? JsonObject
            sourceText?.let { values ->
                val kept = buildJsonObject {
                    for (key in listOf("before", "highlight", "after")) {
                        text(values[key], allowControls = true)?.let { put(key, it) }
                    }
                }
                if (kept.isNotEmpty()) put("text", kept)
            }
        })
    }

    fun canonical(value: JsonElement): String = when (value) {
        is JsonObject -> value.toSortedMap().entries.joinToString(",", "{", "}") { (key, entry) ->
            "${JsonPrimitive(key)}:${canonical(entry)}"
        }
        is JsonArray -> value.joinToString(",", "[", "]", transform = ::canonical)
        is JsonPrimitive -> if (value.isString) value.toString() else {
            val number = value.doubleOrNull
            if (number != null) BigDecimal(number.toString()).stripTrailingZeros().toPlainString() else value.toString()
        }
    }
}
