package com.enve.silo

import com.enve.silo.dto.SiloCollection
import com.enve.silo.dto.SiloProblem
import kotlinx.serialization.json.Json
import retrofit2.Response
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

internal data class SiloPageStart(val cursor: String?, val skip: Int = 0)

internal data class SiloPageWindow<T>(val items: List<T>, val next: SiloPageStart?)

internal suspend fun <T> siloFillPage(
    start: SiloPageStart,
    size: Int,
    fetch: suspend (cursor: String?) -> SiloCollection<T>,
): SiloPageWindow<T> {
    val items = mutableListOf<T>()
    var cursor = start.cursor
    var skip = start.skip
    while (true) {
        val page = fetch(cursor)
        val available = page.items.drop(skip)
        val taken = minOf(size - items.size, available.size)
        items += available.take(taken)
        val next = page.nextCursor()
        when {
            taken < available.size -> return SiloPageWindow(items, SiloPageStart(cursor, skip + taken))
            next == null -> return SiloPageWindow(items, null)
            items.size == size -> return SiloPageWindow(items, SiloPageStart(next))
        }
        if (next == cursor) error("Silo returned the same page cursor twice")
        cursor = next
        skip = 0
    }
}

internal suspend fun <T> siloCollectAll(fetch: suspend (cursor: String?) -> SiloCollection<T>): List<T> {
    val items = mutableListOf<T>()
    var cursor: String? = null
    while (true) {
        val page = fetch(cursor)
        items += page.items
        val next = page.nextCursor() ?: return items
        if (next == cursor) error("Silo returned the same page cursor twice")
        cursor = next
    }
}

private fun SiloCollection<*>.nextCursor(): String? = page?.nextCursor?.takeIf { it.isNotBlank() }

private val problemJson = Json { ignoreUnknownKeys = true; isLenient = true; coerceInputValues = true }

internal fun Response<*>.siloProblem(): SiloProblem? {
    if (isSuccessful) return null
    val raw = errorBody()?.string()?.takeIf { it.isNotBlank() } ?: return null
    return runCatching { problemJson.decodeFromString(SiloProblem.serializer(), raw) }.getOrNull()
}

internal fun siloFailure(prefix: String, response: Response<*>, problem: SiloProblem? = response.siloProblem()): Nothing {
    val reason = problem?.detail?.takeIf { it.isNotBlank() } ?: response.message()
    error("$prefix: HTTP ${response.code()} $reason".trim())
}

internal fun <T> Response<T>.siloBody(prefix: String): T {
    if (!isSuccessful) siloFailure(prefix, this)
    return body() ?: error("$prefix: empty response body")
}

private val siloInstantFormat = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

internal fun siloInstant(epochMillis: Long): String = siloInstantFormat.format(Instant.ofEpochMilli(epochMillis))

internal fun siloInstantMillis(raw: String?): Long? =
    raw?.takeIf { it.isNotBlank() }?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }
