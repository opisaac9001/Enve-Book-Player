package com.enve.audiobookshelf.listening

import kotlinx.serialization.Serializable
import java.time.LocalDate
import java.time.format.TextStyle
import java.util.Locale
import java.util.UUID

@Serializable
data class AbsLocalListeningSession(
    val id: String,
    val connectionId: String,
    val libraryItemId: String,
    val episodeId: String? = null,
    val displayTitle: String,
    val displayAuthor: String? = null,
    val day: String,
    val dayOfWeek: String,
    val durationSec: Double,
    val timeListeningSec: Double,
    val currentTimeSec: Double,
    val startedAtMs: Long,
    val updatedAtMs: Long,
    val needsUpload: Boolean = true,
    val accountId: String? = null,
    val historicalBackfill: Boolean = false,
    val sourceBookKey: String? = null,
)

data class AbsListeningEntry(
    val connectionId: String,
    val libraryItemId: String,
    val episodeId: String?,
    val displayTitle: String,
    val displayAuthor: String?,
    val durationSec: Double,
    val currentTimeSec: Double,
    val listenedMs: Long,
)

object AbsLocalListeningLedger {
    private const val RETENTION_DAYS = 30L

    fun record(
        sessions: List<AbsLocalListeningSession>,
        entry: AbsListeningEntry,
        nowMs: Long,
        today: LocalDate,
        newId: () -> String = { UUID.randomUUID().toString() },
    ): List<AbsLocalListeningSession> {
        if (entry.listenedMs <= 0L) return sessions
        val day = today.toString()
        val listenedSec = entry.listenedMs / 1_000.0
        val existing = sessions.indexOfFirst {
            it.accountId == null && it.connectionId == entry.connectionId && it.libraryItemId == entry.libraryItemId &&
                it.episodeId == entry.episodeId && it.day == day
        }
        val updated = if (existing >= 0) {
            sessions.toMutableList().apply {
                val session = this[existing]
                this[existing] = session.copy(
                    timeListeningSec = session.timeListeningSec + listenedSec,
                    currentTimeSec = entry.currentTimeSec,
                    durationSec = entry.durationSec,
                    updatedAtMs = nowMs,
                    needsUpload = true,
                )
            }
        } else {
            sessions + AbsLocalListeningSession(
                id = newId(),
                connectionId = entry.connectionId,
                libraryItemId = entry.libraryItemId,
                episodeId = entry.episodeId,
                displayTitle = entry.displayTitle,
                displayAuthor = entry.displayAuthor,
                day = day,
                dayOfWeek = today.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.ENGLISH),
                durationSec = entry.durationSec,
                timeListeningSec = listenedSec,
                currentTimeSec = entry.currentTimeSec,
                startedAtMs = nowMs - entry.listenedMs,
                updatedAtMs = nowMs,
            )
        }
        val cutoff = today.minusDays(RETENTION_DAYS).toString()
        return updated.filter { it.needsUpload || it.day >= cutoff }
    }

    fun markUploaded(
        sessions: List<AbsLocalListeningSession>,
        uploaded: List<AbsLocalListeningSession>,
        rejectedIds: Set<String>,
    ): List<AbsLocalListeningSession> {
        val sentVersions = uploaded.associate { it.id to it.updatedAtMs }
        return sessions
            .filterNot { it.id in rejectedIds }
            .map { session ->
                if (sentVersions[session.id] == session.updatedAtMs) session.copy(needsUpload = false) else session
            }
    }
}
