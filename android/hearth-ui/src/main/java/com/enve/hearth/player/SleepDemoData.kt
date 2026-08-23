package com.enve.hearth.player

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import com.enve.engine.sleep.SleepPeriod
import com.enve.engine.sleep.SleepStageKind
import com.enve.engine.sleep.SleepStageSegment
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

internal object SleepDemoData {
    private const val MINUTE_MS = 60_000L

    fun build(
        nowMs: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): SleepInsightsSummary {
        val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
        val nights = (0 until 14).map { index -> night(today.minusDays(index.toLong() + 1L), index, zone) }
        val naps = listOf(
            nap(today.minusDays(2), 14, 10, 42, zone),
            nap(today.minusDays(8), 15, 5, 31, zone),
        )
        val books = listOf(
            Book(id = "demo-clockmaker", title = "The Clockmaker's Moon", source = BookSource.GRIMMORY),
            Book(id = "demo-north-woods", title = "North Woods", source = BookSource.GRIMMORY),
        )
        val history = buildList {
            val historyAnchor = today.minusDays(20).atTime(12, 0).atZone(zone).toInstant().toEpochMilli()
            add(session("demo-history-anchor", books.first(), historyAnchor, historyAnchor + 5L * MINUTE_MS))
            nights.forEachIndexed { index, period ->
                if (index % 3 != 1) {
                    val beforeMinutes = 28L + (index % 4) * 7L
                    val start = period.sleepOnsetTimeMs - beforeMinutes * MINUTE_MS
                    val end = if (index % 2 == 0) {
                        period.sleepOnsetTimeMs + (8L + index % 3) * MINUTE_MS
                    } else {
                        period.sleepOnsetTimeMs - 3L * MINUTE_MS
                    }
                    add(session("demo-bedtime-$index", books[index % books.size], start, end))
                }
            }
        }
        return SleepInsightsPolicy.build(
            periods = nights + naps,
            sessions = history,
            books = books,
            nowMs = nowMs,
            zone = zone,
        )
    }

    private fun night(date: LocalDate, index: Int, zone: ZoneId): SleepPeriod {
        val bedtimeShift = listOf(8L, -12L, 22L, -4L, 31L, 4L, -18L)[index % 7]
        val start = date.atTime(22, 48).plusMinutes(bedtimeShift).atZone(zone).toInstant().toEpochMilli()
        val latency = (12L + index % 5 * 3L) * MINUTE_MS
        val totalSleep = (7L * 60L + 8L + (index * 17L % 47L)) * MINUTE_MS
        val overnightAwake = (5L + index % 4 * 2L) * MINUTE_MS
        val onset = start + latency
        val portions = listOf(20L, 16L, 18L, 10L, 16L, 8L, 12L).map { totalSleep * it / 100L }.toMutableList()
        portions[portions.lastIndex] += totalSleep - portions.sum()
        val kinds = listOf(
            SleepStageKind.LIGHT,
            SleepStageKind.DEEP,
            SleepStageKind.LIGHT,
            SleepStageKind.REM,
            SleepStageKind.LIGHT,
            SleepStageKind.DEEP,
            SleepStageKind.REM,
        )
        var cursor = start
        val stages = buildList {
            add(SleepStageSegment(cursor, onset, SleepStageKind.AWAKE))
            cursor = onset
            kinds.forEachIndexed { stageIndex, kind ->
                val end = cursor + portions[stageIndex]
                add(SleepStageSegment(cursor, end, kind))
                cursor = end
                if (stageIndex == 3) {
                    add(SleepStageSegment(cursor, cursor + overnightAwake, SleepStageKind.AWAKE))
                    cursor += overnightAwake
                }
            }
        }
        val durations = stages.groupBy(SleepStageSegment::kind).mapValues { (_, values) ->
            values.sumOf { it.endTimeMs - it.startTimeMs }
        }
        return SleepPeriod(
            id = "demo-night-$date",
            sleepDayEpochDay = date.toEpochDay(),
            startTimeMs = start,
            sleepOnsetTimeMs = onset,
            endTimeMs = cursor,
            totalSleepMs = totalSleep,
            stages = stages,
            stageDurationsMs = durations,
            latencyMs = latency,
            efficiency = totalSleep.toDouble() / (cursor - start),
            awakenings = 1,
            hasDetailedStages = true,
            isNap = false,
            sourceName = "Enve Demo Watch",
            sourcePackage = "com.enve.demo.sleep",
        )
    }

    private fun nap(
        date: LocalDate,
        hour: Int,
        minute: Int,
        durationMinutes: Long,
        zone: ZoneId,
    ): SleepPeriod {
        val start = date.atTime(hour, minute).atZone(zone).toInstant().toEpochMilli()
        val end = start + durationMinutes * MINUTE_MS
        val stages = listOf(SleepStageSegment(start, end, SleepStageKind.LIGHT))
        return SleepPeriod(
            id = "demo-nap-$date",
            sleepDayEpochDay = date.toEpochDay(),
            startTimeMs = start,
            sleepOnsetTimeMs = start,
            endTimeMs = end,
            totalSleepMs = end - start,
            stages = stages,
            stageDurationsMs = mapOf(SleepStageKind.LIGHT to end - start),
            latencyMs = 0L,
            efficiency = 1.0,
            awakenings = 0,
            hasDetailedStages = true,
            isNap = true,
            sourceName = "Enve Demo Watch",
            sourcePackage = "com.enve.demo.sleep",
        )
    }

    private fun session(id: String, book: Book, startMs: Long, endMs: Long): HistorySession =
        HistorySession(
            id = id,
            bookId = book.id,
            bookKey = book.uniqueKey,
            source = book.source,
            mediaType = AppMediaType.AUDIOBOOK,
            startTimeMs = startMs,
            endTimeMs = endMs,
            activeDurationSeconds = (endMs - startMs) / 1_000L,
        )
}
