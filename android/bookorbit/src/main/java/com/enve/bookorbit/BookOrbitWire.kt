package com.enve.bookorbit

import com.enve.bookorbit.dto.BookOrbitErrorDto
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import retrofit2.Response
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

private val UNSUPPORTED_ENDPOINT_CODES = setOf(404, 405, 501)
private const val MAX_SERVER_MESSAGE_LENGTH = 200

internal fun bookOrbitHttpMessage(prefix: String, response: Response<*>): String =
    "$prefix: HTTP ${response.code()} ${response.message()}".trim()

internal fun <T> bookOrbitOptionalRows(label: String, response: Response<List<T>>): List<T> = when {
    response.isSuccessful -> response.body().orEmpty()
    response.code() in UNSUPPORTED_ENDPOINT_CODES -> emptyList()
    else -> error(bookOrbitHttpMessage(label, response))
}

class BookOrbitRequestException(
    val httpStatus: Int,
    val serverMessage: String?,
    label: String,
) : IllegalStateException("$label: HTTP $httpStatus")

private val errorJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
}

internal fun bookOrbitFailure(label: String, response: Response<*>): BookOrbitRequestException {
    val message = runCatching {
        response.errorBody()?.string()?.takeIf { it.isNotBlank() }?.let { raw ->
            when (val element = errorJson.decodeFromString(BookOrbitErrorDto.serializer(), raw).message) {
                is JsonPrimitive -> element.content.takeIf { element.isString }
                is JsonArray -> (element.firstOrNull() as? JsonPrimitive)?.content
                else -> null
            }
        }
    }.getOrNull()?.trim()?.take(MAX_SERVER_MESSAGE_LENGTH)?.takeIf { it.isNotEmpty() }
    return BookOrbitRequestException(response.code(), message, label)
}

internal fun <T : Any> bookOrbitBody(label: String, response: Response<T>): T {
    if (!response.isSuccessful) throw bookOrbitFailure(label, response)
    return response.body() ?: throw BookOrbitRequestException(response.code(), null, label)
}

internal fun bookOrbitDateMillis(raw: String?): Long? {
    if (raw.isNullOrBlank()) return null
    return runCatching { Instant.parse(raw).toEpochMilli() }.getOrNull()
        ?: runCatching { OffsetDateTime.parse(raw).toInstant().toEpochMilli() }.getOrNull()
        ?: runCatching { LocalDateTime.parse(raw, DateTimeFormatter.ISO_DATE_TIME).toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull()
        ?: runCatching { LocalDate.parse(raw, DateTimeFormatter.ISO_DATE).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull()
        ?: raw.toLongOrNull()?.let { if (it > 1_000_000_000_000L) it else it * 1000L }
}
