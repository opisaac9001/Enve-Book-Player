package com.enve.hearth.player

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.HistorySession
import com.enve.engine.sleep.SleepDataAccess
import com.enve.engine.sleep.SleepPeriod
import com.enve.engine.sleep.SleepStageKind
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs

data class SleepNightListening(
    val bookTitle: String,
    val listeningBeforeSleepMs: Long,
    val gapToSleepMs: Long?,
    val playbackAfterSleepMs: Long,
)

data class SleepNightInsight(
    val period: SleepPeriod,
    val listening: SleepNightListening?,
) {
    val hadBedtimeListening: Boolean
        get() = (listening?.listeningBeforeSleepMs ?: 0L) >= SleepInsightsPolicy.BEDTIME_LISTENING_THRESHOLD_MS
}

data class SleepListeningComparison(
    val nightsWithListening: Int,
    val nightsWithoutListening: Int,
    val averageSleepWithMs: Long,
    val averageSleepWithoutMs: Long,
    val averageLatencyWithMs: Long?,
    val averageLatencyWithoutMs: Long?,
    val averageEfficiencyWith: Double?,
    val averageEfficiencyWithout: Double?,
    val averageRemWith: Double?,
    val averageRemWithout: Double?,
    val averageDeepWith: Double?,
    val averageDeepWithout: Double?,
)

data class BedtimeListeningOverview(
    val nights: Int,
    val totalListeningMs: Long,
    val averageListeningMs: Long?,
    val topBookTitle: String?,
)

data class SleepInsightsSummary(
    val nights: List<SleepNightInsight>,
    val naps: List<SleepPeriod>,
    val averageSleepMs: Long?,
    val averageBedtimeOffsetMinutes: Int?,
    val averageWakeOffsetMinutes: Int?,
    val scheduleConsistencyMinutes: Int?,
    val averageBedtimeListeningMs: Long?,
    val averagePlaybackAfterSleepMs: Long?,
    val topBedtimeBookTitle: String?,
    val matchedNights: Int,
    val comparison: SleepListeningComparison?,
    val listeningOverview: BedtimeListeningOverview,
)

data class SleepTrackerUiState(
    val access: SleepDataAccess = SleepDataAccess.PERMISSION_REQUIRED,
    val loading: Boolean = false,
    val summary: SleepInsightsSummary? = null,
    val isDemo: Boolean = false,
)

object SleepInsightsPolicy {
    const val BEDTIME_LISTENING_THRESHOLD_MS = 5L * 60L * 1_000L
    private const val PRE_SLEEP_WINDOW_MS = 3L * 60L * 60L * 1_000L
    private const val LOOKBACK_MS = 30L * 24L * 60L * 60L * 1_000L

    fun build(
        periods: List<SleepPeriod>,
        sessions: List<HistorySession>,
        books: List<Book>,
        nowMs: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): SleepInsightsSummary {
        val titleByKey = books.associate { it.uniqueKey to it.title }
        val titleById = books.associate { it.id to it.title }
        val audiobookSessions = sessions
            .asSequence()
            .filter { it.mediaType == AppMediaType.AUDIOBOOK && it.endTimeMs > it.startTimeMs }
            .distinctBy(HistorySession::id)
            .toList()
        val nights = periods.filterNot(SleepPeriod::isNap)
            .sortedByDescending(SleepPeriod::startTimeMs)
            .map { period ->
                SleepNightInsight(
                    period = period,
                    listening = listeningFor(period, audiobookSessions, titleByKey, titleById),
                )
            }
        val linked = nights.filter(SleepNightInsight::hadBedtimeListening)
        val continued = linked.mapNotNull(SleepNightInsight::listening).filter { it.playbackAfterSleepMs > 0L }
        val offsets = nights.map { night ->
            val anchor = LocalDate.ofEpochDay(night.period.sleepDayEpochDay).atTime(12, 0).atZone(zone).toInstant().toEpochMilli()
            ((night.period.startTimeMs - anchor) / 60_000L).toInt() to
                ((night.period.endTimeMs - anchor) / 60_000L).toInt()
        }
        val bedtimeAverage = offsets.map { it.first }.averageInt()
        val wakeAverage = offsets.map { it.second }.averageInt()
        val consistency = if (bedtimeAverage != null && wakeAverage != null) {
            ((offsets.sumOf { abs(it.first - bedtimeAverage) + abs(it.second - wakeAverage) }) /
                (offsets.size * 2.0)).toInt()
        } else null
        val historyStart = audiobookSessions.minOfOrNull(HistorySession::startTimeMs)
        return SleepInsightsSummary(
            nights = nights,
            naps = periods.filter(SleepPeriod::isNap).sortedByDescending(SleepPeriod::startTimeMs),
            averageSleepMs = nights.map { it.period.totalSleepMs }.averageLong(),
            averageBedtimeOffsetMinutes = bedtimeAverage?.toInt(),
            averageWakeOffsetMinutes = wakeAverage?.toInt(),
            scheduleConsistencyMinutes = consistency,
            averageBedtimeListeningMs = linked.mapNotNull(SleepNightInsight::listening)
                .map(SleepNightListening::listeningBeforeSleepMs).averageLong(),
            averagePlaybackAfterSleepMs = continued.map(SleepNightListening::playbackAfterSleepMs).averageLong(),
            topBedtimeBookTitle = linked.mapNotNull(SleepNightInsight::listening)
                .groupBy(SleepNightListening::bookTitle)
                .maxByOrNull { (_, values) -> values.sumOf(SleepNightListening::listeningBeforeSleepMs) }
                ?.key,
            matchedNights = linked.size,
            comparison = comparison(nights, historyStart),
            listeningOverview = listeningOverview(
                audiobookSessions.filter { it.endTimeMs >= nowMs - LOOKBACK_MS },
                titleByKey,
                titleById,
                zone,
            ),
        )
    }

    private fun listeningFor(
        period: SleepPeriod,
        sessions: List<HistorySession>,
        titleByKey: Map<String, String>,
        titleById: Map<String, String>,
    ): SleepNightListening? {
        val windowStart = period.sleepOnsetTimeMs - PRE_SLEEP_WINDOW_MS
        val relevant = sessions.filter { it.startTimeMs < period.sleepOnsetTimeMs && it.endTimeMs > windowStart }
        val before = relevant.sumOf { activeOverlap(it, windowStart, period.sleepOnsetTimeMs) }
        if (before < 60_000L) return null
        val last = relevant.maxBy(HistorySession::endTimeMs)
        val after = relevant.sumOf { activeOverlap(it, period.sleepOnsetTimeMs, period.endTimeMs) }
        return SleepNightListening(
            bookTitle = titleByKey[last.bookKey] ?: titleById[last.bookId] ?: "Unknown audiobook",
            listeningBeforeSleepMs = before,
            gapToSleepMs = if (after > 0L) null else (period.sleepOnsetTimeMs - last.endTimeMs).coerceAtLeast(0L),
            playbackAfterSleepMs = after,
        )
    }

    private fun activeOverlap(session: HistorySession, startMs: Long, endMs: Long): Long {
        val wallDuration = session.endTimeMs - session.startTimeMs
        if (wallDuration <= 0L) return 0L
        val overlap = (minOf(session.endTimeMs, endMs) - maxOf(session.startTimeMs, startMs)).coerceAtLeast(0L)
        val activeRatio = (session.activeDurationSeconds * 1_000.0 / wallDuration).coerceIn(0.0, 1.0)
        return (overlap * activeRatio).toLong()
    }

    private fun comparison(nights: List<SleepNightInsight>, historyStartMs: Long?): SleepListeningComparison? {
        if (historyStartMs == null) return null
        val eligible = nights.filter { it.period.sleepOnsetTimeMs >= historyStartMs }
        val with = eligible.filter(SleepNightInsight::hadBedtimeListening)
        val without = eligible.filterNot(SleepNightInsight::hadBedtimeListening)
        if (with.isEmpty() || without.isEmpty()) return null
        return SleepListeningComparison(
            nightsWithListening = with.size,
            nightsWithoutListening = without.size,
            averageSleepWithMs = with.map { it.period.totalSleepMs }.averageLong() ?: return null,
            averageSleepWithoutMs = without.map { it.period.totalSleepMs }.averageLong() ?: return null,
            averageLatencyWithMs = with.mapNotNull { it.period.latencyMs }.averageLong(),
            averageLatencyWithoutMs = without.mapNotNull { it.period.latencyMs }.averageLong(),
            averageEfficiencyWith = with.mapNotNull { it.period.efficiency }.averageDouble(),
            averageEfficiencyWithout = without.mapNotNull { it.period.efficiency }.averageDouble(),
            averageRemWith = with.mapNotNull { stageFraction(it.period, SleepStageKind.REM) }.averageDouble(),
            averageRemWithout = without.mapNotNull { stageFraction(it.period, SleepStageKind.REM) }.averageDouble(),
            averageDeepWith = with.mapNotNull { stageFraction(it.period, SleepStageKind.DEEP) }.averageDouble(),
            averageDeepWithout = without.mapNotNull { stageFraction(it.period, SleepStageKind.DEEP) }.averageDouble(),
        )
    }

    private fun stageFraction(period: SleepPeriod, kind: SleepStageKind): Double? {
        val duration = period.stageDurationsMs[kind] ?: return null
        return if (duration > 0L && period.totalSleepMs > 0L) duration.toDouble() / period.totalSleepMs else null
    }

    private fun listeningOverview(
        sessions: List<HistorySession>,
        titleByKey: Map<String, String>,
        titleById: Map<String, String>,
        zone: ZoneId,
    ): BedtimeListeningOverview {
        val bedtime = sessions.filter {
            val hour = Instant.ofEpochMilli(it.startTimeMs).atZone(zone).hour
            hour >= 20 || hour < 4
        }
        val nights = bedtime.map {
            Instant.ofEpochMilli(it.startTimeMs).atZone(zone).minusHours(12).toLocalDate()
        }.distinct().size
        val total = bedtime.sumOf { it.activeDurationSeconds * 1_000L }
        val top = bedtime.groupBy(HistorySession::bookKey)
            .maxByOrNull { (_, values) -> values.sumOf(HistorySession::activeDurationSeconds) }
            ?.let { (key, values) -> titleByKey[key] ?: titleById[values.first().bookId] }
        return BedtimeListeningOverview(
            nights = nights,
            totalListeningMs = total,
            averageListeningMs = if (nights > 0) total / nights else null,
            topBookTitle = top,
        )
    }

    private fun List<Long>.averageLong(): Long? = if (isEmpty()) null else sum() / size
    private fun List<Int>.averageInt(): Double? = if (isEmpty()) null else average()
    private fun List<Double>.averageDouble(): Double? = if (isEmpty()) null else average()
}
