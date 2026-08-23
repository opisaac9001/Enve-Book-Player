package com.enve.core.data.util

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.roundToLong

fun normalizeFraction(value: Float?): Float {
    val raw = value ?: return 0f
    return if (raw > 1f) (raw / 100f).coerceIn(0f, 1f) else raw.coerceIn(0f, 1f)
}

fun resolveDurationSeconds(
    durationSeconds: Long?,
    durationValue: Double?,
    durationMs: Long?,
): Long {
    durationSeconds?.takeIf { it > 0L }?.let { return it }
    durationMs?.takeIf { it > 0L }?.let { return it / 1000L }

    val raw = durationValue ?: return 0L
    if (raw <= 0.0) return 0L

    return if (raw > 10_000.0) (raw / 1000.0).roundToLong() else raw.roundToLong()
}

fun parseServerDate(value: String?): Long {
    if (value.isNullOrBlank()) return 0L
    return runCatching { Instant.parse(value).toEpochMilli() }
        .recoverCatching { LocalDate.parse(value).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli() }
        .getOrDefault(0L)
}

fun resolveAudiobookPositionSeconds(
    positionMs: Long?,
    percentage: Float?,
    durationSeconds: Long?,
    duration: Double?,
): Long {
    val durationValue = resolveDurationSeconds(durationSeconds = durationSeconds, durationValue = duration, durationMs = null)
    val fraction = normalizeFraction(percentage)
    val fromPercent = if (durationValue > 0 && fraction > 0f) (durationValue * fraction).roundToLong() else 0L

    val raw = positionMs ?: return fromPercent
    if (raw <= 0L) return fromPercent

    val normalizedSeconds = raw / 1000L

    val clamped = if (durationValue > 0L) normalizedSeconds.coerceIn(0L, durationValue) else normalizedSeconds.coerceAtLeast(0L)
    return if (clamped > 0L) clamped else fromPercent
}
