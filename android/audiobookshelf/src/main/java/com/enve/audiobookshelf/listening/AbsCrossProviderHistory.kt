package com.enve.audiobookshelf.listening

import com.enve.core.data.model.HistorySession
import com.enve.core.data.model.HistorySessionOrigin
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.audiobookshelf.dto.AbsMediaProgressDto
import java.security.MessageDigest
import java.nio.ByteBuffer
import java.time.Instant
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale
import java.util.UUID

object AbsCrossProviderHistory {
    fun session(
        source: HistorySession,
        targetConnectionId: String,
        targetAccountId: String,
        targetItemId: String,
        targetTitle: String,
        targetAuthor: String?,
        targetDurationSec: Long,
        currentProgressSec: Double,
        historicalBackfill: Boolean = false,
    ): AbsLocalListeningSession? {
        if (source.origin != HistorySessionOrigin.LOCAL || source.source != BookSource.GRIMMORY ||
            source.mediaType != AppMediaType.AUDIOBOOK || source.connectionId.isNullOrBlank() ||
            source.connectionId == targetConnectionId || source.activeDurationSeconds < 10L ||
            targetAccountId.isBlank() || targetItemId.isBlank() || currentProgressSec < 0.0
        ) return null
        val wallClockSec = (source.endTimeMs - source.startTimeMs).coerceAtLeast(0L) / 1_000.0
        val actualSec = source.activeDurationSeconds.toDouble().coerceAtMost(wallClockSec)
        if (actualSec < 10.0) return null
        val date = Instant.ofEpochMilli(source.endTimeMs).atZone(ZoneId.systemDefault()).toLocalDate()
        val identity = listOf(source.connectionId, targetConnectionId, targetAccountId, targetItemId, source.id)
            .joinToString("\u0000")
        val bytes = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray(Charsets.UTF_8)).copyOf(16)
        bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x40).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
        val buffer = ByteBuffer.wrap(bytes)
        return AbsLocalListeningSession(
            id = UUID(buffer.long, buffer.long).toString(),
            connectionId = targetConnectionId,
            libraryItemId = targetItemId,
            displayTitle = targetTitle,
            displayAuthor = targetAuthor,
            day = date.toString(),
            dayOfWeek = date.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.ENGLISH),
            durationSec = targetDurationSec.coerceAtLeast(0L).toDouble(),
            timeListeningSec = actualSec,
            currentTimeSec = currentProgressSec,
            startedAtMs = source.startTimeMs,
            updatedAtMs = source.endTimeMs,
            accountId = targetAccountId,
            sourceBookKey = source.bookKey,
            historicalBackfill = historicalBackfill,
        )
    }

    fun mayUpload(session: AbsLocalListeningSession, targetProgressUpdatedAtMs: Long?): Boolean =
        !session.historicalBackfill || (targetProgressUpdatedAtMs != null &&
            targetProgressUpdatedAtMs > session.updatedAtMs)

    fun readyForUpload(
        pending: List<AbsLocalListeningSession>,
        progressByItem: Map<String, Result<AbsMediaProgressDto?>>,
    ): List<AbsLocalListeningSession> = pending.filter { session ->
        if (session.accountId == null) return@filter true
        val progress = progressByItem[session.libraryItemId] ?: return@filter false
        progress.isSuccess && mayUpload(session, progress.getOrNull()?.lastUpdate)
    }

    fun uploadPosition(session: AbsLocalListeningSession, remotePosition: Double?, pendingLocalPosition: Double?): Double =
        if (session.accountId == null && session.episodeId == null && pendingLocalPosition != null) {
            pendingLocalPosition.coerceAtLeast(0.0)
        } else remotePosition?.coerceAtLeast(0.0) ?: 0.0

    fun enqueue(existing: List<AbsLocalListeningSession>, session: AbsLocalListeningSession): List<AbsLocalListeningSession> =
        if (existing.any { it.id == session.id }) existing else existing + session
}
