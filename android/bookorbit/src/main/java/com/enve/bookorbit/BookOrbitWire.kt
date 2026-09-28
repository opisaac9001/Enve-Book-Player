package com.enve.bookorbit

import retrofit2.Response
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

private val UNSUPPORTED_ENDPOINT_CODES = setOf(404, 405, 501)

internal fun bookOrbitHttpMessage(prefix: String, response: Response<*>): String =
    "$prefix: HTTP ${response.code()} ${response.message()}".trim()

internal fun <T> bookOrbitOptionalRows(label: String, response: Response<List<T>>): List<T> = when {
    response.isSuccessful -> response.body().orEmpty()
    response.code() in UNSUPPORTED_ENDPOINT_CODES -> emptyList()
    else -> error(bookOrbitHttpMessage(label, response))
}

internal fun bookOrbitDateMillis(raw: String?): Long? {
    if (raw.isNullOrBlank()) return null
    return runCatching { Instant.parse(raw).toEpochMilli() }.getOrNull()
        ?: runCatching { OffsetDateTime.parse(raw).toInstant().toEpochMilli() }.getOrNull()
        ?: runCatching { LocalDateTime.parse(raw, DateTimeFormatter.ISO_DATE_TIME).toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull()
        ?: runCatching { LocalDate.parse(raw, DateTimeFormatter.ISO_DATE).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull()
        ?: raw.toLongOrNull()?.let { if (it > 1_000_000_000_000L) it else it * 1000L }
}
