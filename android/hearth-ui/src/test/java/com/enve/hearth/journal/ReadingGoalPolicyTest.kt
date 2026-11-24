package com.enve.hearth.journal

import com.enve.core.data.local.DailyReadingGoal
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

class ReadingGoalPolicyTest {
    private val pacific = ZoneId.of("America/Los_Angeles")
    private val goal = DailyReadingGoal(enabled = true, minutes = 20)

    @Test
    fun completionRequiresTheExactGoalSeconds() {
        val now = local("2026-11-14T21:00")
        val almost = ReadingGoalPolicy.progress(goal, listOf(session("a", local("2026-11-14T20:00"), 1_199L)), now, pacific)
        val exact = ReadingGoalPolicy.progress(goal, listOf(session("a", local("2026-11-14T20:00"), 1_200L)), now, pacific)

        assertFalse(almost.complete)
        assertEquals(19L, almost.readMinutes)
        assertEquals(1L, almost.remainingMinutes)
        assertTrue(exact.complete)
        assertEquals(0L, exact.remainingMinutes)
        assertEquals(1f, exact.fraction)
    }

    @Test
    fun onlyTodaysEbookReadingCounts() {
        val now = local("2026-11-14T21:00")
        val reading = session("reading", local("2026-11-14T08:00"), 300L)
        val sessions = listOf(
            reading,
            reading,
            reading.copy(id = "mirrored"),
            session("listening", local("2026-11-14T09:00"), 900L, AppMediaType.AUDIOBOOK),
            session("podcast", local("2026-11-14T10:00"), 900L, AppMediaType.PODCAST),
            session("yesterday", local("2026-11-13T23:59"), 900L),
            session("future", local("2026-11-14T21:01"), 900L),
            session("empty", local("2026-11-14T11:00"), 0L),
        )

        val progress = ReadingGoalPolicy.progress(goal, sessions, now, pacific)

        assertEquals(300L, progress.readSeconds)
        assertEquals(LocalDate.of(2026, 11, 14), progress.day)
    }

    @Test
    fun dayBoundaryFollowsTheZoneAcrossDaylightSaving() {
        val sessions = listOf(
            session("before-midnight", local("2026-03-07T23:59"), 600L),
            session("after-midnight", local("2026-03-08T00:30"), 300L),
            session("after-gap", local("2026-03-08T03:30"), 300L),
        )

        val springForward = ReadingGoalPolicy.progress(goal, sessions, local("2026-03-08T23:00"), pacific)
        val nextDay = ReadingGoalPolicy.progress(goal, sessions, local("2026-03-09T00:01"), pacific)

        assertEquals(600L, springForward.readSeconds)
        assertEquals(LocalDate.of(2026, 3, 8), springForward.day)
        assertEquals(0L, nextDay.readSeconds)
        assertEquals(LocalDate.of(2026, 3, 9), nextDay.day)
    }

    @Test
    fun disabledGoalIsNeverComplete() {
        val now = local("2026-11-14T21:00")
        val progress = ReadingGoalPolicy.progress(
            DailyReadingGoal(enabled = false, minutes = 1),
            listOf(session("a", local("2026-11-14T20:00"), 3_600L)),
            now,
            pacific,
        )

        assertEquals(3_600L, progress.readSeconds)
        assertFalse(progress.complete)
    }

    private fun local(value: String): Long =
        LocalDateTime.parse(value).atZone(pacific).toInstant().toEpochMilli()

    private fun session(
        id: String,
        endMs: Long,
        seconds: Long,
        mediaType: AppMediaType = AppMediaType.EBOOK,
    ) = HistorySession(
        id = id,
        bookId = "book",
        bookKey = "LOCAL:book",
        source = BookSource.LOCAL,
        mediaType = mediaType,
        startTimeMs = endMs - seconds * 1_000L,
        endTimeMs = endMs,
        activeDurationSeconds = seconds,
    )
}
