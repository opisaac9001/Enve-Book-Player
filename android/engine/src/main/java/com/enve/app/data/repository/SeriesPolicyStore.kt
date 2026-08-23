package com.enve.app.data.repository

import com.enve.core.data.local.PreferencesManager
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

@Serializable
data class SeriesPolicy(
    val autoDownloadNext: Boolean? = null,
    val autoDelete: Boolean? = null,
    val downloadAheadCount: Int? = null,
)

private val seriesPolicyJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = false
}

@Singleton
class SeriesPolicyStore @Inject constructor(
    private val prefs: PreferencesManager,
) {
    private fun parse(raw: String): Map<String, SeriesPolicy> = runCatching {
        if (raw.isBlank()) emptyMap() else seriesPolicyJson.decodeFromString<Map<String, SeriesPolicy>>(raw)
    }.getOrDefault(emptyMap())

    val all: Flow<Map<String, SeriesPolicy>> = prefs.seriesPolicyJson.map(::parse)

    fun policyFor(seriesKey: String): Flow<SeriesPolicy?> = all.map { it[seriesKey] }

    suspend fun update(seriesKey: String, transform: (SeriesPolicy) -> SeriesPolicy) {
        val current = parse(prefs.seriesPolicyJson.first()).toMutableMap()
        val next = transform(current[seriesKey] ?: SeriesPolicy())
        if (next == SeriesPolicy()) {
            current.remove(seriesKey)
        } else {
            current[seriesKey] = next
        }
        prefs.setSeriesPolicyJson(seriesPolicyJson.encodeToString<Map<String, SeriesPolicy>>(current))
    }
}

fun seriesKeyFor(connectionId: String?, seriesName: String?): String? {
    val name = seriesName?.trim().orEmpty()
    if (name.isBlank()) return null
    return "${connectionId.orEmpty()}::${name.lowercase()}"
}
