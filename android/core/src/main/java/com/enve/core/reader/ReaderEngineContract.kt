package com.enve.core.reader

import com.enve.core.data.model.BookSource
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.text.Normalizer

@Serializable
enum class ReaderEngineKind {
    @SerialName("readium")
    READIUM,

    @SerialName("foliate")
    FOLIATE,
}

data class ReaderEngineRequest(
    val source: BookSource,
    val format: String?,
    val readAlong: Boolean,
    val isReflowable: Boolean = true,
    val override: ReaderEngineKind? = null,
)

object ReaderEnginePolicy {
    fun requiresFoliateSync(source: BookSource): Boolean = when (source) {
        BookSource.GRIMMORY, BookSource.BOOKORBIT, BookSource.SILO -> true
        else -> false
    }

    fun select(request: ReaderEngineRequest): ReaderEngineKind {
        val isOrdinaryEpub = request.format.equals("EPUB", ignoreCase = true) &&
            request.isReflowable &&
            !request.readAlong
        if (!isOrdinaryEpub) return ReaderEngineKind.READIUM

        request.override?.let { return it }
        return if (requiresFoliateSync(request.source)) ReaderEngineKind.FOLIATE
        else ReaderEngineKind.READIUM
    }
}

object ReaderCheckpointIdentity {
    fun key(
        source: BookSource,
        connectionId: String?,
        bookId: String,
        providerFileId: String?,
        publicationSha256: String,
    ): String = buildString {
        append("v1|")
        append(source.name)
        append('|')
        appendLengthPrefixed(connectionId.orEmpty())
        append('|')
        appendLengthPrefixed(bookId)
        append('|')
        appendLengthPrefixed(providerFileId.orEmpty())
        append('|')
        append(publicationSha256.lowercase())
    }

    private fun StringBuilder.appendLengthPrefixed(value: String) {
        append(value.length)
        append(':')
        append(value)
    }
}

@Serializable
data class ReaderDomPoint(
    val cssSelector: String,
    val textNodeIndex: Int,
    val charOffset: Int? = null,
)

@Serializable
data class ReaderDomRange(
    val start: ReaderDomPoint,
    val end: ReaderDomPoint? = null,
)

@Serializable
data class ReaderTextQuote(
    val exact: String,
    val prefix: String? = null,
    val suffix: String? = null,
)

@Serializable
data class ReaderVisibleAnchor(
    val cssSelector: String? = null,
    val domRange: ReaderDomRange? = null,
    val textQuote: ReaderTextQuote? = null,
)

@Serializable
data class EpubBridgeCheckpoint(
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val publicationSha256: String,
    val providerFileId: String? = null,
    val revision: Long = 0,
    val writerEpoch: Long = 0,
    val observedAt: Long,
    val sourceEngine: ReaderEngineKind,
    val href: String? = null,
    val epubCfi: String? = null,
    val cssSelector: String? = null,
    val domRange: ReaderDomRange? = null,
    val resourceProgression: Double? = null,
    val totalProgression: Double? = null,
    val textQuote: ReaderTextQuote? = null,
    val nativeReadiumLocatorJson: String? = null,
) {
    val hasPortableAnchor: Boolean
        get() = !href.isNullOrBlank() && (
            !cssSelector.isNullOrBlank() ||
                domRange != null ||
                !textQuote?.exact.isNullOrBlank()
            )

    val hasPreciseAnchor: Boolean
        get() = (
            sourceEngine == ReaderEngineKind.FOLIATE &&
                EpubBridgeCheckpointCodec.isFullEpubCfi(epubCfi)
            ) || hasPortableAnchor

    fun forPublication(
        sha256: String,
        fileId: String?,
    ): EpubBridgeCheckpoint {
        if (publicationSha256 == sha256 && providerFileId == fileId) return this
        return copy(
            publicationSha256 = sha256,
            providerFileId = fileId,
            href = null,
            epubCfi = null,
            cssSelector = null,
            domRange = null,
            resourceProgression = null,
            totalProgression = null,
            textQuote = null,
            nativeReadiumLocatorJson = null,
            observedAt = 0L,
        )
    }

    companion object {
        const val CURRENT_SCHEMA_VERSION = 1
    }
}

object EpubBridgeCheckpointCodec {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    fun encode(checkpoint: EpubBridgeCheckpoint): String =
        json.encodeToString(checkpoint)

    fun decode(value: String?): EpubBridgeCheckpoint? {
        val raw = value?.trim()?.takeIf { it.startsWith("{") } ?: return null
        return runCatching { json.decodeFromString<EpubBridgeCheckpoint>(raw) }.getOrNull()
    }

    fun fromReadiumLocator(
        locatorJson: String,
        publicationSha256: String,
        providerFileId: String?,
        writerEpoch: Long,
        revision: Long,
        observedAt: Long,
    ): EpubBridgeCheckpoint? {
        val root = runCatching { json.parseToJsonElement(locatorJson).jsonObject }.getOrNull()
            ?: return null
        val href = root.string("href")
        val locations = root["locations"] as? JsonObject ?: JsonObject(emptyMap())
        val domRange = (locations["domRange"] as? JsonObject)?.let {
            runCatching { json.decodeFromJsonElement(ReaderDomRange.serializer(), it) }.getOrNull()
        }
        val text = root["text"] as? JsonObject
        val exact = text?.string("highlight")?.compactAnchorText()
        return EpubBridgeCheckpoint(
            publicationSha256 = publicationSha256,
            providerFileId = providerFileId,
            revision = revision,
            writerEpoch = writerEpoch,
            observedAt = observedAt,
            sourceEngine = ReaderEngineKind.READIUM,
            href = href,
            epubCfi = null,
            cssSelector = locations.string("cssSelector"),
            domRange = domRange,
            resourceProgression = locations.double("progression")?.boundedProgress(),
            totalProgression = locations.double("totalProgression")?.boundedProgress(),
            textQuote = exact?.takeIf { it.isNotBlank() }?.let {
                ReaderTextQuote(
                    exact = it,
                    prefix = text.string("before")?.compactAnchorText()?.takeLast(TEXT_CONTEXT_LENGTH),
                    suffix = text.string("after")?.compactAnchorText()?.take(TEXT_CONTEXT_LENGTH),
                )
            },
            nativeReadiumLocatorJson = locatorJson,
        )
    }

    fun toReadiumLocatorJson(checkpoint: EpubBridgeCheckpoint): String? {
        val href = checkpoint.href?.takeIf { it.isNotBlank() } ?: return null
        val locations = buildJsonObject {
            checkpoint.resourceProgression?.boundedProgress()?.let { put("progression", it) }
            checkpoint.totalProgression?.boundedProgress()?.let { put("totalProgression", it) }
            checkpoint.cssSelector?.takeIf { it.isNotBlank() }?.let { put("cssSelector", it) }
            checkpoint.domRange?.let {
                put("domRange", json.encodeToJsonElement(ReaderDomRange.serializer(), it))
            }
        }
        return buildJsonObject {
            put("href", href)
            put("type", "application/xhtml+xml")
            if (locations.isNotEmpty()) put("locations", locations)
            checkpoint.textQuote?.takeIf { it.exact.isNotBlank() }?.let { quote ->
                put("text", buildJsonObject {
                    quote.prefix?.takeIf { it.isNotBlank() }?.let { put("before", it) }
                    put("highlight", quote.exact)
                    quote.suffix?.takeIf { it.isNotBlank() }?.let { put("after", it) }
                })
            }
        }.toString()
    }

    fun decodeVisibleAnchor(value: String?): ReaderVisibleAnchor? {
        val raw = value?.trim()?.takeIf { it.startsWith("{") } ?: return null
        return runCatching { json.decodeFromString<ReaderVisibleAnchor>(raw) }
            .getOrNull()
            ?.takeIf { !it.textQuote?.exact.isNullOrBlank() }
    }

    fun withVisibleAnchor(
        locatorJson: String,
        anchor: ReaderVisibleAnchor,
        epubCfi: String? = null,
    ): String? {
        val root = runCatching { json.parseToJsonElement(locatorJson).jsonObject }.getOrNull()
            ?: return null
        val existingLocations = root["locations"] as? JsonObject ?: JsonObject(emptyMap())
        val locations = JsonObject(
            existingLocations.toMutableMap().apply {
                anchor.cssSelector?.takeIf { it.isNotBlank() }?.let {
                    put("cssSelector", kotlinx.serialization.json.JsonPrimitive(it))
                }
                anchor.domRange?.let {
                    put(
                        "domRange",
                        json.encodeToJsonElement(ReaderDomRange.serializer(), it),
                    )
                }
                remove("fragments")
                if (epubCfi != null && isFullEpubCfi(epubCfi)) {
                    put("cfi", kotlinx.serialization.json.JsonPrimitive(epubCfi))
                } else {
                    remove("cfi")
                }
            },
        )
        return JsonObject(
            root.toMutableMap().apply {
                put("locations", locations)
                anchor.textQuote?.takeIf { it.exact.isNotBlank() }?.let { quote ->
                    put("text", buildJsonObject {
                        quote.prefix?.takeIf { it.isNotBlank() }?.let { put("before", it) }
                        put("highlight", quote.exact)
                        quote.suffix?.takeIf { it.isNotBlank() }?.let { put("after", it) }
                    })
                }
            },
        ).toString()
    }

    fun cfi(value: String?): String? {
        val raw = value?.trim()?.takeIf { it.isNotBlank() } ?: return null
        if (raw.isWrappedEpubCfi()) return raw
        decode(raw)?.epubCfi?.takeIf(String::isWrappedEpubCfi)?.let { return it }
        val root = runCatching { json.parseToJsonElement(raw).jsonObject }.getOrNull() ?: return null
        val locations = root["locations"] as? JsonObject ?: return null
        val fragments = locations["fragments"] as? JsonArray
        return fragments
            ?.firstNotNullOfOrNull { element ->
                runCatching { element.jsonPrimitive.content }.getOrNull()
                    ?.takeIf(String::isWrappedEpubCfi)
            }
            ?: locations.string("cfi")?.takeIf(String::isWrappedEpubCfi)
    }

    fun foliateCfi(value: String?): String? {
        val raw = value?.trim()?.takeIf { it.isNotBlank() } ?: return null
        decode(raw)?.let { checkpoint ->
            return checkpoint.epubCfi
                ?.takeIf { checkpoint.sourceEngine == ReaderEngineKind.FOLIATE }
                ?.takeIf(::isFullEpubCfi)
        }
        return null
    }

    fun isFullEpubCfi(value: String?): Boolean {
        val raw = value?.trim() ?: return false
        if (!raw.isWrappedEpubCfi()) return false
        val body = raw.removePrefix("epubcfi(").removeSuffix(")")
        if (body.any { it.isISOControl() } || body.any { it in "<>{}\"'" }) return false

        var escaped = false
        var bracketDepth = 0
        var bangIndex = -1
        for ((index, character) in body.withIndex()) {
            if (escaped) {
                escaped = false
                continue
            }
            if (character == '^') {
                escaped = true
                continue
            }
            when (character) {
                '[' -> bracketDepth += 1
                ']' -> {
                    bracketDepth -= 1
                    if (bracketDepth < 0) return false
                }
                '!' -> {
                    if (bracketDepth != 0 || bangIndex >= 0) return false
                    bangIndex = index
                }
            }
        }
        if (escaped || bracketDepth != 0 || bangIndex <= 0 || bangIndex >= body.lastIndex) {
            return false
        }
        val packagePath = body.substring(0, bangIndex)
        val contentPath = body.substring(bangIndex + 1)
        return packagePath.isCfiPathComponent(allowRange = false) &&
            contentPath.isCfiPathComponent(allowRange = true)
    }

    fun href(value: String?): String? {
        val raw = value?.trim()?.takeIf { it.startsWith("{") } ?: return null
        decode(raw)?.href?.takeIf { it.isNotBlank() }?.let { return it }
        return runCatching { json.parseToJsonElement(raw).jsonObject.string("href") }
            .getOrNull()
            ?.takeIf { it.isNotBlank() }
    }

    private fun JsonObject.string(key: String): String? =
        runCatching { this[key]?.jsonPrimitive?.content }.getOrNull()
            ?.takeIf { it.isNotBlank() }

    private fun JsonObject.double(key: String): Double? =
        runCatching { this[key]?.jsonPrimitive?.doubleOrNull }.getOrNull()

    private fun String.compactAnchorText(): String =
        Normalizer.normalize(this, Normalizer.Form.NFC)
            .replace(Regex("\\s+"), " ")
            .trim()

    private fun Double.boundedProgress(): Double? =
        takeIf { it.isFinite() }?.coerceIn(0.0, 1.0)

    private fun String.isCfiPathComponent(allowRange: Boolean): Boolean {
        if (!startsWith("/") || endsWith("/") || contains("//")) return false
        if (!allowRange && contains(',')) return false
        val branches = if (allowRange) split(',') else listOf(this)
        if (branches.size != 1 && branches.size != 3) return false
        if (branches.first().isBlank()) return false
        if (branches.size == 3 && branches.drop(1).all { it.isBlank() }) return false
        return branches.filter { it.isNotBlank() }.all { branch ->
            val normalized = if (branch.startsWith("/")) branch else "/$branch"
            Regex("""/\d+""").containsMatchIn(normalized) &&
                normalized
                    .split('/')
                    .drop(1)
                    .all { step -> step.firstOrNull()?.isDigit() == true }
        }
    }

    private const val TEXT_CONTEXT_LENGTH = 64
}

object EpubBridgeRestoreMatcher {
    fun restoredWithFoliateCfi(
        expected: EpubBridgeCheckpoint,
        restoreMethod: String,
    ): Boolean =
        restoreMethod == "cfi" &&
            expected.sourceEngine == ReaderEngineKind.FOLIATE &&
            EpubBridgeCheckpointCodec.isFullEpubCfi(expected.epubCfi)

    fun restoredWithPortableAnchor(
        expected: EpubBridgeCheckpoint,
        restoreMethod: String,
    ): Boolean =
        when (restoreMethod) {
            "textQuote" -> !expected.textQuote?.exact.isNullOrBlank()
            "domRange" -> expected.domRange != null
            "cssSelector" -> !expected.cssSelector.isNullOrBlank()
            else -> false
        }

    fun canBootstrapFoliateCfi(
        expected: EpubBridgeCheckpoint,
        actual: EpubBridgeCheckpoint,
        restoreMethod: String,
    ): Boolean =
        restoreMethod == "progression" &&
            expected.totalProgression != null &&
            expected.href.isNullOrBlank() &&
            !expected.hasPreciseAnchor &&
            !expected.hasPortableAnchor &&
            actual.sourceEngine == ReaderEngineKind.FOLIATE &&
            EpubBridgeCheckpointCodec.isFullEpubCfi(actual.epubCfi)

    fun matchesPortableRestoreCapture(
        expected: EpubBridgeCheckpoint,
        actual: EpubBridgeCheckpoint,
    ): Boolean =
        expected.hasPortableAnchor &&
            actual.hasPortableAnchor &&
            hrefMatches(expected.href, actual.href)

    fun matches(
        expected: EpubBridgeCheckpoint,
        actual: EpubBridgeCheckpoint,
    ): Boolean {
        if (!expected.href.isNullOrBlank() && !hrefMatches(expected.href, actual.href)) return false

        expected.textQuote?.exact?.compactAnchorText()?.takeIf { it.isNotBlank() }?.let {
            if (actual.textQuote?.exact?.compactAnchorText() != it) return false
        }
        expected.cssSelector?.takeIf { it.isNotBlank() }?.let {
            if (actual.cssSelector != it) return false
        }
        expected.domRange?.let {
            if (actual.domRange != it) return false
        }

        val expectedProgress = expected.totalProgression ?: expected.resourceProgression
        val actualProgress = actual.totalProgression ?: actual.resourceProgression
        if (expectedProgress != null && actualProgress != null) {
            val tolerance = if (expected.hasPortableAnchor) 0.03 else 0.005
            if (kotlin.math.abs(expectedProgress - actualProgress) > tolerance) return false
        } else if (expectedProgress != null) {
            return expected.hasPortableAnchor && actual.hasPortableAnchor
        }
        return true
    }

    fun hrefMatches(expected: String?, actual: String?): Boolean {
        val expectedHref = expected.normalizedHref() ?: return actual.isNullOrBlank()
        val actualHref = actual.normalizedHref() ?: return false
        return expectedHref == actualHref ||
            expectedHref.endsWith("/$actualHref") ||
            actualHref.endsWith("/$expectedHref")
    }

    private fun String?.normalizedHref(): String? =
        this
            ?.trim()
            ?.substringBefore('#')
            ?.removePrefix("./")
            ?.replace("%20", " ")
            ?.takeIf { it.isNotBlank() }

    private fun String.compactAnchorText(): String =
        Normalizer.normalize(this, Normalizer.Form.NFC)
            .replace(Regex("\\s+"), " ")
            .trim()
}

private fun String?.isWrappedEpubCfi(): Boolean =
    this != null && startsWith("epubcfi(") && endsWith(")")
