package com.enve.hearth.journal

import com.enve.core.data.model.HistorySession
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

internal object ReadingHistory {
    private const val MINUTE_MS = 60_000L

    fun validSessions(sessions: List<HistorySession>, nowMs: Long): List<HistorySession> =
        sessions.asSequence()
            .filter { it.activeDurationSeconds > 0L && it.endTimeMs <= nowMs }
            .sortedWith(compareBy<HistorySession>({ it.id }, { it.origin }, { it.endTimeMs }))
            .distinctBy(HistorySession::id)
            .distinctBy { Triple(it.bookKey, it.startTimeMs, it.endTimeMs) }
            .toList()

    fun day(epochMs: Long, zone: ZoneId): LocalDate =
        Instant.ofEpochMilli(epochMs).atZone(zone).toLocalDate()

    fun minuteTicks(): Flow<Long> = flow {
        while (true) {
            val now = System.currentTimeMillis()
            emit(now)
            delay(MINUTE_MS - now % MINUTE_MS)
        }
    }
}
