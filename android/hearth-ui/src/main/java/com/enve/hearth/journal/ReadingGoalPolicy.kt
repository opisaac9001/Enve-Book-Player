package com.enve.hearth.journal

import com.enve.core.data.local.DailyReadingGoal
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.HistorySession
import java.time.LocalDate
import java.time.ZoneId

data class DailyGoalProgress(
    val goal: DailyReadingGoal,
    val readSeconds: Long,
    val day: LocalDate,
) {
    val complete: Boolean get() = goal.enabled && readSeconds >= goal.seconds
    val fraction: Float get() = (readSeconds.toFloat() / goal.seconds).coerceIn(0f, 1f)
    val readMinutes: Long get() = readSeconds / 60L
    val remainingMinutes: Long get() = ((goal.seconds - readSeconds).coerceAtLeast(0L) + 59L) / 60L
}

internal object ReadingGoalPolicy {
    fun progress(
        goal: DailyReadingGoal,
        sessions: List<HistorySession>,
        nowMs: Long,
        zone: ZoneId,
    ): DailyGoalProgress {
        val today = ReadingHistory.day(nowMs, zone)
        val todayStartMs = today.atStartOfDay(zone).toInstant().toEpochMilli()
        val readSeconds = ReadingHistory.validSessions(sessions, nowMs)
            .filter { it.mediaType == AppMediaType.EBOOK && it.endTimeMs >= todayStartMs }
            .sumOf(HistorySession::activeDurationSeconds)
        return DailyGoalProgress(goal, readSeconds, today)
    }
}
