package com.enve.hearth.journal

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset

class JournalInsightsPolicyTest {
    @Test
    fun comparesMondayBasedWeeksAndBuildsStreaks() {
        val now = instant("2026-07-29T12:00:00Z")
        val book = book("book", "Author", "Narrator")
        val sessions = listOf(
            session("mon", book, "2026-07-27T12:00:00Z", 3_600L),
            session("tue", book, "2026-07-28T12:00:00Z", 1_800L),
            session("sun", book, "2026-07-26T12:00:00Z", 7_200L),
        )

        val snapshot = JournalInsightsPolicy.snapshot(
            books = listOf(book),
            sessions = sessions,
            selectedYear = 2026,
            nowMs = now,
            zone = ZoneOffset.UTC,
        )

        assertEquals(5_400L, snapshot.thisWeekSeconds)
        assertEquals(7_200L, snapshot.lastWeekSeconds)
        assertEquals(3, snapshot.currentStreak)
        assertEquals(3, snapshot.longestStreak)
    }

    @Test
    fun annualReviewUsesOnlySelectedYear() {
        val finished = book("finished", "Octavia Butler", "Robin Miles").copy(
            isFinished = true,
            lastReadTime = instant("2026-06-12T12:00:00Z"),
        )
        val future = book("future", "Future Author", "Future Narrator").copy(
            isFinished = true,
            lastReadTime = instant("2026-12-12T12:00:00Z"),
        )
        val sessions = listOf(
            session("older", finished, "2025-12-31T12:00:00Z", 9_000L),
            session("current", finished, "2026-06-10T12:00:00Z", 3_600L),
        )

        val snapshot = JournalInsightsPolicy.snapshot(
            books = listOf(finished, future),
            sessions = sessions,
            selectedYear = 2026,
            nowMs = instant("2026-07-29T12:00:00Z"),
            zone = ZoneOffset.UTC,
        )

        assertEquals(3_600L, snapshot.yearReview.totalSeconds)
        assertEquals(1, snapshot.yearReview.booksFinished)
        assertEquals(finished.id, snapshot.yearReview.topBook?.book?.id)
        assertEquals("Octavia Butler", snapshot.yearReview.topAuthor?.name)
        assertEquals("Robin Miles", snapshot.yearReview.topNarrator?.name)
        assertEquals(listOf(2026, 2025), snapshot.availableYears)
    }

    private fun book(id: String, author: String, narrator: String) = Book(
        id = id,
        title = id,
        author = author,
        narrator = narrator,
        source = BookSource.LOCAL,
        connectionId = "unit",
        libraryId = "library",
    )

    private fun session(
        id: String,
        book: Book,
        endedAt: String,
        durationSeconds: Long,
    ) = HistorySession(
        id = id,
        bookId = book.id,
        bookKey = book.uniqueKey,
        connectionId = book.connectionId,
        source = book.source,
        mediaType = AppMediaType.AUDIOBOOK,
        startTimeMs = instant(endedAt) - durationSeconds * 1_000L,
        endTimeMs = instant(endedAt),
        activeDurationSeconds = durationSeconds,
    )

    private fun instant(value: String): Long = Instant.parse(value).toEpochMilli()
}
