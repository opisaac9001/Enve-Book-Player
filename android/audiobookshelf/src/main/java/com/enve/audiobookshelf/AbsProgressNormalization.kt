package com.enve.audiobookshelf

import com.enve.audiobookshelf.dto.AbsMediaProgressDto
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book

internal fun applyAbsMediaProgress(base: Book, progress: AbsMediaProgressDto): Book {
    val durationSec = progress.duration
        ?.takeIf { it > 0.0 }
        ?.let { normalizeAbsDurationSeconds(it, base.duration.takeIf { d -> d > 0L }) }
        ?: base.duration
    val audioProgress = progress.progress?.coerceIn(0f, 1f) ?: base.readProgress
    val ebookProgress = progress.ebookProgress?.coerceIn(0f, 1f)
        ?: base.epubProgress.takeIf { base.mediaType == AppMediaType.EBOOK || base.hasEbook }
    val currentTimeSec = normalizeAbsCurrentTimeSeconds(
        rawCurrentTime = progress.currentTime,
        durationSec = durationSec,
        progressFraction = progress.progress,
        fallbackSec = base.currentTime,
    )
    val lastReadTime = progress.lastUpdate
        ?.takeIf { it > 0L }
        ?.let { if (it < 100_000_000_000L) it * 1000L else it }
        ?: base.lastReadTime

    return base.copy(
        duration = durationSec,
        currentTime = currentTimeSec,
        readProgress = audioProgress,
        epubProgress = ebookProgress,
        epubLocator = progress.ebookLocation
            ?: base.epubLocator.takeIf { ebookProgress == base.epubProgress },
        lastReadTime = lastReadTime,
        isFinished = progress.resolvedIsFinished || (ebookProgress ?: 0f) >= 0.99f,
        serverReadStatus = null,
    )
}

internal fun normalizeAbsDurationSeconds(rawDuration: Double, referenceDurationSec: Long?): Long {
    if (rawDuration <= 0.0) return 0L
    val raw = rawDuration.toLong()
    if (raw <= 0L) return 0L
    val ref = referenceDurationSec?.takeIf { it > 0L }
    if (ref != null) {
        if (raw > ref * 10L) return (raw / 1000L).coerceAtLeast(1L)
        return raw
    }
    return if (raw > 1_000_000L) (raw / 1000L).coerceAtLeast(1L) else raw
}

internal fun normalizeAbsCurrentTimeSeconds(
    rawCurrentTime: Double?,
    durationSec: Long,
    progressFraction: Float?,
    fallbackSec: Long?,
): Long {
    val computedFromProgress = progressFraction
        ?.coerceIn(0f, 1f)
        ?.let { pct -> if (durationSec > 0L) (durationSec * pct).toLong() else null }
    val raw = rawCurrentTime?.takeIf { it >= 0.0 }?.toLong()
    val normalized = when {
        raw == null -> null
        durationSec > 0L && raw > durationSec * 10L -> raw / 1000L
        raw > 10_000_000L -> raw / 1000L
        else -> raw
    }
    val candidate = normalized?.takeIf { it > 0L }
        ?: computedFromProgress ?: normalized ?: fallbackSec ?: 0L
    return if (durationSec > 0L) candidate.coerceIn(0L, durationSec) else candidate.coerceAtLeast(0L)
}
