package com.enve.core.data.sync

import kotlin.math.roundToLong
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull

data class AudioLocatorPosition(
    val timeMs: Long?,
    val progression: Double,
) {
    companion object {
        private val json = Json { isLenient = true }

        fun isAudioLocator(locatorJson: String?): Boolean = parse(locatorJson) != null

        fun parse(locatorJson: String?): AudioLocatorPosition? {
            val locator = locatorJson
                ?.trim()
                ?.takeIf { it.startsWith("{") }
                ?.let { runCatching { json.parseToJsonElement(it) }.getOrNull() } as? JsonObject
                ?: return null
            val type = (locator["type"] as? JsonPrimitive)?.contentOrNull?.lowercase().orEmpty()
            val href = (locator["href"] as? JsonPrimitive)?.contentOrNull?.lowercase().orEmpty()
            if (!type.contains("audio") && !href.startsWith("audiobook://")) return null

            val locations = locator["locations"] as? JsonObject
            val timeMs = (locations?.get("fragments") as? JsonArray)
                ?.firstNotNullOfOrNull { fragment ->
                    (fragment as? JsonPrimitive)?.contentOrNull
                        ?.takeIf { it.startsWith("t=") }
                        ?.removePrefix("t=")
                        ?.substringBefore(',')
                        ?.toDoubleOrNull()
                }
                ?.let { (it * 1000.0).roundToLong().coerceAtLeast(0L) }
            val progression = (locations?.get("totalProgression") as? JsonPrimitive)?.doubleOrNull ?: 0.0
            return AudioLocatorPosition(timeMs, progression.coerceIn(0.0, 1.0))
        }
    }
}
