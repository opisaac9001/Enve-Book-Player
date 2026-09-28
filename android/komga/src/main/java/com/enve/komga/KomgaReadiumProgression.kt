package com.enve.komga

import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.util.nonBlankStringOrNull
import com.enve.core.data.util.optArray
import com.enve.core.data.util.optDouble
import com.enve.core.data.util.optInt
import com.enve.core.data.util.optNonBlankString
import com.enve.core.data.util.optObject
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.komga.dto.KomgaR2Device
import com.enve.komga.dto.KomgaR2Locations
import com.enve.komga.dto.KomgaR2Locator
import com.enve.komga.dto.KomgaR2LocatorText
import com.enve.komga.dto.KomgaR2Progression
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import java.time.OffsetDateTime

internal object KomgaReadiumProgression {
    private const val XHTML = "application/xhtml+xml"
    private val device = KomgaR2Device(id = "enve-android", name = "Enve")
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    fun locatorFrom(readerLocator: String?, totalProgression: Float): KomgaR2Locator? {
        val readium = EpubBridgeCheckpointCodec.decode(readerLocator)
            ?.let { it.nativeReadiumLocatorJson ?: EpubBridgeCheckpointCodec.toReadiumLocatorJson(it) }
            ?: readerLocator
        val root = readium?.trim()?.takeIf { it.startsWith("{") }
            ?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
            ?: return null
        val href = root.optNonBlankString("href")?.substringBefore('#')?.takeIf { it.isNotEmpty() } ?: return null
        val locations = root.optObject("locations")
        val text = root.optObject("text")
        return KomgaR2Locator(
            href = href,
            type = root.optNonBlankString("type") ?: XHTML,
            title = root.optNonBlankString("title"),
            locations = KomgaR2Locations(
                fragment = locations?.optArray("fragments")
                    ?.mapNotNull { it.nonBlankStringOrNull() }
                    ?.filter { '=' !in it && !it.startsWith("epubcfi(") }
                    ?.takeIf { it.isNotEmpty() },
                progression = locations?.optDouble("progression")?.coerceIn(0.0, 1.0),
                position = locations?.optInt("position"),
                totalProgression = totalProgression.toDouble().coerceIn(0.0, 1.0),
            ),
            text = text?.optNonBlankString("highlight")?.let { highlight ->
                KomgaR2LocatorText(
                    before = text.optNonBlankString("before"),
                    highlight = highlight,
                    after = text.optNonBlankString("after"),
                )
            },
        )
    }

    fun snapToPositions(
        locator: KomgaR2Locator?,
        totalProgression: Float,
        positions: List<KomgaR2Locator>,
    ): KomgaR2Locator? {
        val total = totalProgression.toDouble().coerceIn(0.0, 1.0)
        val locations = locator?.locations
        val progression = locations?.progression
        val resource = positions.filter { it.href == locator?.href }
        if (locator == null || locations == null || progression == null || resource.isEmpty()) {
            val anchor = positions.lastOrNull { (it.locations?.totalProgression ?: 0.0) <= total }
                ?: positions.firstOrNull()
                ?: return null
            return anchor.copy(locations = anchor.locations?.copy(totalProgression = total))
        }
        val anchor = resource.lastOrNull { (it.locations?.progression ?: 0.0) <= progression } ?: resource.first()
        return locator.copy(
            locations = locations.copy(
                progression = anchor.locations?.progression,
                position = anchor.locations?.position,
            ),
        )
    }

    fun encode(locator: KomgaR2Locator, modifiedAtMs: Long): String =
        json.encodeToString(
            KomgaR2Progression(
                modified = Instant.ofEpochMilli(modifiedAtMs).toString(),
                device = device,
                locator = locator,
            ),
        )

    fun snapshot(progression: KomgaR2Progression): SyncSnapshot? {
        val locator = progression.locator
        val href = locator.href.substringBefore('#').takeIf { it.isNotBlank() } ?: return null
        val locations = locator.locations ?: return null
        val total = locations.totalProgression ?: return null
        val fragments = locations.fragment.orEmpty()
            .ifEmpty { listOfNotNull(locator.href.substringAfter('#', "").takeIf { it.isNotEmpty() }) }
        val readium = buildJsonObject {
            put("href", href)
            put("type", locator.type.ifBlank { XHTML })
            locator.title?.let { put("title", it) }
            put(
                "locations",
                buildJsonObject {
                    if (fragments.isNotEmpty()) put("fragments", JsonArray(fragments.map(::JsonPrimitive)))
                    locations.progression?.let { put("progression", it) }
                    locations.position?.let { put("position", it) }
                    put("totalProgression", total)
                },
            )
            locator.text?.takeIf { it.highlight != null }?.let { text ->
                put(
                    "text",
                    buildJsonObject {
                        text.before?.let { put("before", it) }
                        text.highlight?.let { put("highlight", it) }
                        text.after?.let { put("after", it) }
                    },
                )
            }
        }
        return SyncSnapshot(
            percentage = total.toFloat().coerceIn(0f, 1f),
            locatorJson = readium.toString(),
            href = href,
            source = "Komga",
            updatedAt = runCatching { OffsetDateTime.parse(progression.modified).toInstant().toEpochMilli() }.getOrNull(),
        )
    }
}
