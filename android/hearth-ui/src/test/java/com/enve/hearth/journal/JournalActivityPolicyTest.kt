package com.enve.hearth.journal

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset

class JournalActivityPolicyTest {
    @Test
    fun weeklyTotalsUseActiveSessionDuration() {
        val now = instant("2026-07-29T12:00:00Z")
        val sessions = listOf(
            session("audio", AppMediaType.AUDIOBOOK, "2026-07-27T10:00:00Z", 3_600L),
            session("ebook", AppMediaType.EBOOK, "2026-07-28T10:00:00Z", 1_800L),
            session("prior-week", AppMediaType.AUDIOBOOK, "2026-07-26T10:00:00Z", 7_200L),
        )

        val stats = JournalActivityPolicy.stats(emptyList(), sessions, now, ZoneOffset.UTC)

        assertEquals(60, stats.listeningMinutes)
        assertEquals(30, stats.readingMinutes)
    }

    @Test
    fun streakAllowsTodayOrYesterdayAsItsLeadingDay() {
        val now = instant("2026-07-29T12:00:00Z")
        val sessions = listOf(
            session("today", AppMediaType.EBOOK, "2026-07-29T10:00:00Z", 60L),
            session("yesterday", AppMediaType.AUDIOBOOK, "2026-07-28T10:00:00Z", 60L),
            session("monday", AppMediaType.EBOOK, "2026-07-27T10:00:00Z", 60L),
            session("gap", AppMediaType.EBOOK, "2026-07-25T10:00:00Z", 60L),
        )

        assertEquals(
            3,
            JournalActivityPolicy.stats(emptyList(), sessions, now, ZoneOffset.UTC).streakNights,
        )
    }

    @Test
    fun heatmapUsesDailyActiveSeconds() {
        val now = instant("2026-07-29T12:00:00Z")
        val sessions = listOf(
            session("yesterday", AppMediaType.EBOOK, "2026-07-28T10:00:00Z", 30L),
            session("today", AppMediaType.AUDIOBOOK, "2026-07-29T10:00:00Z", 60L),
        )

        val heatmap = JournalActivityPolicy.heatmap(sessions, now, ZoneOffset.UTC)

        assertEquals(0.5f, heatmap[heatmap.lastIndex - 1])
        assertEquals(1f, heatmap.last())
    }

    private fun session(
        id: String,
        mediaType: AppMediaType,
        endedAt: String,
        durationSeconds: Long,
    ) = HistorySession(
        id = id,
        bookId = id,
        bookKey = "LOCAL:$id",
        source = BookSource.LOCAL,
        mediaType = mediaType,
        startTimeMs = instant(endedAt) - durationSeconds * 1_000L,
        endTimeMs = instant(endedAt),
        activeDurationSeconds = durationSeconds,
    )

    private fun instant(value: String): Long = Instant.parse(value).toEpochMilli()
}
