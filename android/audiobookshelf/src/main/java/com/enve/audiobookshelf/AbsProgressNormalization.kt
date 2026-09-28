package com.enve.audiobookshelf

import com.enve.audiobookshelf.dto.AbsMediaProgressDto
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.util.FINISHED_PROGRESS_THRESHOLD
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.EpubCfi
import com.enve.core.reader.MediaOverlayTimeline
import kotlin.math.abs
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal fun applyAbsMediaProgress(base: Book, progress: AbsMediaProgressDto): Book {
    val isDual = base.hasAudio && base.hasEbook
    val keepsAudioSide = isDual && !absHasAudioPosition(progress)
    val keepsEbookSide = isDual && !absHasEbookPosition(progress)
    val durationSec = progress.duration?.takeIf { it > 0.0 }?.toLong() ?: base.duration
    val audioProgress = if (keepsAudioSide) base.readProgress else progress.progress?.coerceIn(0f, 1f) ?: base.readProgress
    val ebookProgress = if (keepsEbookSide) {
        base.epubProgress
    } else {
        progress.ebookProgress?.coerceIn(0f, 1f)
            ?: base.epubProgress.takeIf { base.mediaType == AppMediaType.EBOOK || base.hasEbook }
    }
    val currentTimeSec = if (keepsAudioSide) {
        base.currentTime
    } else {
        normalizeAbsCurrentTimeSeconds(
            rawCurrentTime = progress.currentTime,
            durationSec = durationSec,
            progressFraction = progress.progress,
            fallbackSec = base.currentTime,
        )
    }
    val lastReadTime = progress.lastUpdate?.takeIf { it > 0L } ?: base.lastReadTime

    return base.copy(
        duration = durationSec,
        currentTime = currentTimeSec,
        readProgress = audioProgress,
        epubProgress = ebookProgress,
        epubLocator = (absServerEbookLocation(progress.ebookLocation) as? AbsServerEbookLocation.ReadiumLocatorJson)?.json
            ?: base.epubLocator.takeIf { ebookProgress == base.epubProgress },
        lastReadTime = lastReadTime,
        isFinished = progress.resolvedIsFinished || (ebookProgress ?: 0f) >= FINISHED_PROGRESS_THRESHOLD,
        serverReadStatus = null,
    )
}

internal fun absHasEbookPosition(record: AbsMediaProgressDto): Boolean =
    (record.ebookProgress ?: 0f) > 0f || !record.ebookLocation.isNullOrBlank()

internal fun absHasAudioPosition(record: AbsMediaProgressDto): Boolean =
    (record.currentTime ?: 0.0) > 0.0 || (record.progress ?: 0f) > 0f || record.isFinished == true

internal sealed interface AbsServerEbookLocation {
    data class ReadiumLocatorJson(val json: String) : AbsServerEbookLocation
    data class Cfi(val cfi: String) : AbsServerEbookLocation
}

internal fun absServerEbookLocation(value: String?): AbsServerEbookLocation? {
    val trimmed = value?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    if (trimmed.startsWith("{") && EpubCfi.jsonObject(trimmed) != null) return AbsServerEbookLocation.ReadiumLocatorJson(trimmed)
    if (trimmed.startsWith("epubcfi(") && EpubCfi.parse(trimmed) != null) return AbsServerEbookLocation.Cfi(trimmed)
    return null
}

internal fun absReadiumLocator(locator: String): String =
    EpubBridgeCheckpointCodec.decode(locator)?.nativeReadiumLocatorJson ?: locator

internal data class AbsAudioPosition(val currentTime: Double, val duration: Double)

internal fun absEbookProgressBody(
    progress: Float,
    ebookLocation: String?,
    itemHasAudio: Boolean,
    audioPosition: AbsAudioPosition?,
): JsonObject = buildJsonObject {
    put("ebookProgress", progress)
    val isFinished = progress >= FINISHED_PROGRESS_THRESHOLD
    if (isFinished || !itemHasAudio) put("isFinished", isFinished)
    if (ebookLocation != null) put("ebookLocation", ebookLocation)
    if (audioPosition != null && audioPosition.duration > 0.0) {
        put("currentTime", audioPosition.currentTime)
        put("duration", audioPosition.duration)
        put("progress", (audioPosition.currentTime / audioPosition.duration).coerceIn(0.0, 1.0))
    }
}

internal fun absItemAudioPosition(
    narrationTime: Double,
    clip: MediaOverlayTimeline.ClipTiming,
    overlayDuration: Double,
    itemAudioDuration: Double,
): AbsAudioPosition? {
    if (!MediaOverlayTimeline.narrationMatchesAudio(overlayDuration, itemAudioDuration)) return null
    if (narrationTime < clip.audioStart - 0.5 || narrationTime > clip.audioEnd + 0.5) return null
    return AbsAudioPosition(narrationTime * itemAudioDuration / overlayDuration, itemAudioDuration)
}

private const val SYNCED_AUDIO_TIME_TOLERANCE_SEC = 0.01

internal fun absItemAudioMovedElsewhere(itemAudioTime: Double, lastSyncedAudioTime: Double?): Boolean =
    lastSyncedAudioTime == null || abs(itemAudioTime - lastSyncedAudioTime) > SYNCED_AUDIO_TIME_TOLERANCE_SEC

internal fun absNarratedLocator(
    itemAudioTime: Double,
    itemAudioDuration: Double,
    timeline: MediaOverlayTimeline,
    serverLocator: String?,
    lastSyncedAudioTime: Double?,
): Pair<String, Double>? {
    if (!absItemAudioMovedElsewhere(itemAudioTime, lastSyncedAudioTime)) return null
    val overlayTime = itemAudioTime * timeline.totalAudioDuration / itemAudioDuration
    val audioClip = timeline.clipIndexAtAudioTime(overlayTime) ?: return null
    val serverClip = serverLocator?.let(timeline::resolveEpub3Locator)?.clipIndex
    if (serverClip != null) {
        val clip = timeline.clipTimings[serverClip]
        if (overlayTime >= clip.audioStart - 5 && overlayTime <= clip.audioEnd + 5) return null
    }
    val locator = timeline.textLocatorJson(audioClip, overlayTime) ?: return null
    return locator to timeline.readingProgression(overlayTime, audioClip)
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
    val candidate = raw?.takeIf { it > 0L }
        ?: computedFromProgress ?: raw ?: fallbackSec ?: 0L
    return if (durationSec > 0L) candidate.coerceIn(0L, durationSec) else candidate.coerceAtLeast(0L)
}

internal data class AbsSeriesEntry(val name: String, val sequence: String?)

internal fun absSeriesEntries(seriesName: String?): List<AbsSeriesEntry> =
    seriesName.orEmpty().split(", ").mapNotNull { part ->
        val trimmed = part.trim()
        if (trimmed.isEmpty()) return@mapNotNull null
        val marker = trimmed.lastIndexOf(" #")
        if (marker < 0) AbsSeriesEntry(trimmed, null)
        else AbsSeriesEntry(trimmed.substring(0, marker), trimmed.substring(marker + 2))
    }
