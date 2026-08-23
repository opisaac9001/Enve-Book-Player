package com.enve.hearth.player

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import com.enve.engine.sleep.SleepPeriod
import com.enve.engine.sleep.SleepStageKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class SleepInsightsPolicyTest {
    @Test
    fun linksBedtimePlaybackAndBuildsComparison() {
        val zone = ZoneId.of("UTC")
        val firstNight = period("2026-08-10T23:00:00Z", "2026-08-11T07:00:00Z")
        val secondNight = period("2026-08-11T23:00:00Z", "2026-08-12T07:00:00Z")
        val book = Book(id = "book-1", title = "Night Book", source = BookSource.GRIMMORY)
        val sessions = listOf(
            session("history", "2026-08-09T12:00:00Z", "2026-08-09T12:10:00Z", 600),
            session("bedtime", "2026-08-10T22:30:00Z", "2026-08-10T23:10:00Z", 2_400),
        )

        val summary = SleepInsightsPolicy.build(
            periods = listOf(secondNight, firstNight),
            sessions = sessions,
            books = listOf(book),
            nowMs = Instant.parse("2026-08-13T12:00:00Z").toEpochMilli(),
            zone = zone,
        )

        val linked = summary.nights.first { it.period.id == firstNight.id }.listening
        assertNotNull(linked)
        assertEquals("Night Book", linked?.bookTitle)
        assertEquals(30 * 60_000L, linked?.listeningBeforeSleepMs)
        assertEquals(10 * 60_000L, linked?.playbackAfterSleepMs)
        assertEquals(1, summary.matchedNights)
        assertEquals(1, summary.comparison?.nightsWithListening)
        assertEquals(1, summary.comparison?.nightsWithoutListening)
    }

    @Test
    fun reportsBedtimeListeningWithoutSleepPeriods() {
        val book = Book(id = "book-1", title = "Night Book", source = BookSource.GRIMMORY)
        val summary = SleepInsightsPolicy.build(
            periods = emptyList(),
            sessions = listOf(session("bedtime", "2026-08-12T21:00:00Z", "2026-08-12T21:30:00Z", 1_800)),
            books = listOf(book),
            nowMs = Instant.parse("2026-08-13T12:00:00Z").toEpochMilli(),
            zone = ZoneId.of("UTC"),
        )

        assertEquals(0, summary.nights.size)
        assertEquals(1, summary.listeningOverview.nights)
        assertEquals(30 * 60_000L, summary.listeningOverview.totalListeningMs)
        assertEquals("Night Book", summary.listeningOverview.topBookTitle)
    }

    @Test
    fun demoDataExercisesEverySleepInsightsSection() {
        val summary = SleepDemoData.build(
            nowMs = Instant.parse("2026-08-14T12:00:00Z").toEpochMilli(),
            zone = ZoneId.of("UTC"),
        )

        assertEquals(14, summary.nights.size)
        assertEquals(2, summary.naps.size)
        assertEquals(9, summary.matchedNights)
        assertNotNull(summary.comparison)
        assertNotNull(summary.averageBedtimeListeningMs)
        assertNotNull(summary.averagePlaybackAfterSleepMs)
        assertEquals(true, summary.nights.first().period.hasDetailedStages)
    }

    private fun period(start: String, end: String): SleepPeriod {
        val startInstant = Instant.parse(start)
        val endInstant = Instant.parse(end)
        return SleepPeriod(
            id = start,
            sleepDayEpochDay = LocalDate.ofInstant(startInstant, ZoneId.of("UTC")).toEpochDay(),
            startTimeMs = startInstant.toEpochMilli(),
            sleepOnsetTimeMs = startInstant.toEpochMilli(),
            endTimeMs = endInstant.toEpochMilli(),
            totalSleepMs = endInstant.toEpochMilli() - startInstant.toEpochMilli(),
            stages = emptyList(),
            stageDurationsMs = mapOf(SleepStageKind.ASLEEP to endInstant.toEpochMilli() - startInstant.toEpochMilli()),
            latencyMs = 0L,
            efficiency = 1.0,
            awakenings = 0,
            hasDetailedStages = false,
            isNap = false,
            sourceName = "Test Watch",
            sourcePackage = "test.watch",
        )
    }

    private fun session(id: String, start: String, end: String, activeSeconds: Long): HistorySession =
        HistorySession(
            id = id,
            bookId = "book-1",
            bookKey = "GRIMMORY:book-1",
            source = BookSource.GRIMMORY,
            mediaType = AppMediaType.AUDIOBOOK,
            startTimeMs = Instant.parse(start).toEpochMilli(),
            endTimeMs = Instant.parse(end).toEpochMilli(),
            activeDurationSeconds = activeSeconds,
        )
}
