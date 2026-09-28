package com.enve.core.data.util

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.roundToLong

fun parseServerDate(value: String?): Long {
    if (value.isNullOrBlank()) return 0L
    return runCatching { Instant.parse(value).toEpochMilli() }
        .recoverCatching { LocalDate.parse(value).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli() }
        .getOrDefault(0L)
}

fun resolveAudiobookPositionSeconds(
    positionMs: Long?,
    fraction: Float,
    durationSeconds: Long,
): Long {
    val clampedFraction = fraction.coerceIn(0f, 1f)
    val fromFraction = if (durationSeconds > 0L && clampedFraction > 0f) (durationSeconds * clampedFraction).roundToLong() else 0L

    val raw = positionMs ?: return fromFraction
    if (raw <= 0L) return fromFraction

    val seconds = raw / 1000L
    val clamped = if (durationSeconds > 0L) seconds.coerceIn(0L, durationSeconds) else seconds
    return if (clamped > 0L) clamped else fromFraction
}
