package com.enve.hearth.journal

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.YearMonth
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.Locale

class ReadingRecapPolicyTest {
    private val pacific = ZoneId.of("America/Los_Angeles")

    @Test
    fun calendarMonthsAreEndExclusiveInTheCurrentZone() {
        val now = local("2026-11-14T12:00", pacific)
        val sessions = listOf(
            session("last-minute", local("2026-10-31T23:59", pacific), 600L),
            session("midnight", local("2026-11-01T00:00", pacific), 300L),
            session("utc-november", instant("2026-11-01T06:30:00Z"), 120L),
        )

        val october = ReadingRecapPolicy.totals(sessions, month("2026-10"), now, pacific)
        val november = ReadingRecapPolicy.totals(sessions, month("2026-11"), now, pacific)
        val utcNovember = ReadingRecapPolicy.totals(sessions, month("2026-11"), now, ZoneOffset.UTC)

        assertEquals(720L, october.totalSeconds)
        assertEquals(2, october.sessions)
        assertEquals(300L, november.totalSeconds)
        assertEquals(1_020L, utcNovember.totalSeconds)
    }

    @Test
    fun leapDayBelongsToFebruaryAndTheYear() {
        val now = instant("2024-12-31T12:00:00Z")
        val sessions = listOf(
            session("leap", instant("2024-02-29T23:00:00Z"), 1_800L),
            session("march", instant("2024-03-01T00:00:00Z"), 600L),
        )

        val february = ReadingRecapPolicy.totals(sessions, month("2024-02"), now, ZoneOffset.UTC)
        val year = ReadingRecapPolicy.totals(sessions, ReadingRecapPeriod.Year(2024), now, ZoneOffset.UTC)

        assertEquals(LocalDate.of(2024, 3, 1), ReadingRecapPeriod.Month(YearMonth.of(2024, 2)).endExclusive)
        assertEquals(1_800L, february.totalSeconds)
        assertEquals(1, february.activeDays)
        assertEquals(RecapDay(LocalDate.of(2024, 2, 29), 1_800L), february.busiestDay)
        assertEquals(2_400L, year.totalSeconds)
        assertEquals(2, year.activeDays)
    }

    @Test
    fun daylightSavingDaysUseLocalCalendarDates() {
        val now = local("2026-11-14T12:00", pacific)
        val sessions = listOf(
            session("before-spring-gap", local("2026-03-07T23:30", pacific), 600L),
            session("after-spring-gap", local("2026-03-08T03:30", pacific), 900L),
            session("first-fall-back-hour", instant("2026-11-01T08:30:00Z"), 400L),
            session("second-fall-back-hour", instant("2026-11-01T09:30:00Z"), 400L),
        )

        val march = ReadingRecapPolicy.totals(sessions, month("2026-03"), now, pacific)
        val november = ReadingRecapPolicy.totals(sessions, month("2026-11"), now, pacific)

        assertEquals(2, march.activeDays)
        assertEquals(RecapDay(LocalDate.of(2026, 3, 8), 900L), march.busiestDay)
        assertEquals(1, november.activeDays)
        assertEquals(RecapDay(LocalDate.of(2026, 11, 1), 800L), november.busiestDay)
    }

    @Test
    fun duplicatesAreRemovedBeforeTotals() {
        val now = instant("2026-11-14T12:00:00Z")
        val end = instant("2026-11-10T12:00:00Z")
        val original = session("one", end, 600L)
        val sessions = listOf(
            original,
            original,
            original.copy(id = "mirrored"),
            session("two", instant("2026-11-11T12:00:00Z"), 300L),
        )

        val recap = ReadingRecapPolicy.totals(sessions, null, now, ZoneOffset.UTC)

        assertEquals(2, recap.sessions)
        assertEquals(900L, recap.totalSeconds)
        assertEquals(listOf(RecapBookTotal("LOCAL:book", AppMediaType.EBOOK, 900L)), recap.bookTotals)
    }

    @Test
    fun futureAndNonPositiveSessionsAreIgnoredEverywhere() {
        val now = instant("2026-11-14T12:00:00Z")
        val sessions = listOf(
            session("valid", instant("2026-11-02T12:00:00Z"), 600L),
            session("future", instant("2026-11-14T12:00:01Z"), 600L),
            session("zero", instant("2026-11-03T12:00:00Z"), 0L),
            session("negative", instant("2020-01-03T12:00:00Z"), -60L),
        )

        val recap = ReadingRecapPolicy.totals(sessions, null, now, ZoneOffset.UTC)

        assertEquals(1, recap.sessions)
        assertEquals(600L, recap.totalSeconds)
        assertFalse(recap.canGoBack)
        assertFalse(recap.canGoForward)
    }

    @Test
    fun listeningIncludesPodcastsAndReadingIsEbooks() {
        val now = instant("2026-11-14T12:00:00Z")
        val sessions = listOf(
            session("audio", instant("2026-11-02T12:00:00Z"), 600L, AppMediaType.AUDIOBOOK, "LOCAL:audio"),
            session("podcast", instant("2026-11-03T12:00:00Z"), 300L, AppMediaType.PODCAST, "LOCAL:podcast"),
            session("ebook", instant("2026-11-04T12:00:00Z"), 1_200L, AppMediaType.EBOOK, "LOCAL:ebook"),
        )

        val recap = ReadingRecapPolicy.totals(sessions, null, now, ZoneOffset.UTC)

        assertEquals(900L, recap.listeningSeconds)
        assertEquals(1_200L, recap.readingSeconds)
        assertEquals(2_100L, recap.totalSeconds)
        assertEquals(listOf("LOCAL:ebook", "LOCAL:audio"), ReadingRecapPolicy.lookupKeys(recap))
    }

    @Test
    fun tiesResolveDeterministically() {
        val now = instant("2026-11-14T12:00:00Z")
        val sessions = listOf(
            session("later", instant("2026-11-09T12:00:00Z"), 600L, bookKey = "LOCAL:b"),
            session("earlier", instant("2026-11-05T12:00:00Z"), 600L, bookKey = "LOCAL:a"),
        )

        val forward = ReadingRecapPolicy.totals(sessions, null, now, ZoneOffset.UTC)
        val reversed = ReadingRecapPolicy.totals(sessions.reversed(), null, now, ZoneOffset.UTC)
        val resolved = ReadingRecapPolicy.resolve(
            forward,
            mapOf(
                "LOCAL:a" to book("a", author = "Zadie Smith"),
                "LOCAL:b" to book("b", author = "Ali Smith"),
            ),
        )

        assertEquals(forward, reversed)
        assertEquals(RecapDay(LocalDate.of(2026, 11, 5), 600L), forward.busiestDay)
        assertEquals(listOf("LOCAL:a", "LOCAL:b"), forward.bookTotals.map(RecapBookTotal::bookKey))
        assertEquals(InsightNamedEntry("Ali Smith", 600L), resolved.topAuthor)
    }

    @Test
    fun navigationIsBoundedByEarliestRecordAndNow() {
        val now = instant("2026-11-14T12:00:00Z")
        val sessions = listOf(
            session("first", instant("2026-08-20T12:00:00Z"), 600L),
            session("latest", instant("2026-11-02T12:00:00Z"), 600L),
        )

        val current = ReadingRecapPolicy.totals(sessions, null, now, ZoneOffset.UTC)
        val earliest = ReadingRecapPolicy.totals(sessions, month("2026-08"), now, ZoneOffset.UTC)
        val beforeHistory = ReadingRecapPolicy.totals(sessions, month("2026-06"), now, ZoneOffset.UTC)
        val future = ReadingRecapPolicy.totals(sessions, month("2027-01"), now, ZoneOffset.UTC)
        val year = ReadingRecapPolicy.totals(sessions, ReadingRecapPeriod.Year(2026), now, ZoneOffset.UTC)
        val empty = ReadingRecapPolicy.totals(emptyList(), null, now, ZoneOffset.UTC)

        assertEquals(month("2026-11"), current.period)
        assertTrue(current.canGoBack)
        assertFalse(current.canGoForward)
        assertFalse(earliest.canGoBack)
        assertTrue(earliest.canGoForward)
        assertEquals(month("2026-08"), beforeHistory.period)
        assertEquals(month("2026-11"), future.period)
        assertFalse(year.canGoBack)
        assertFalse(year.canGoForward)
        assertEquals(month("2026-11"), empty.period)
        assertFalse(empty.canGoBack)
        assertFalse(empty.canGoForward)
    }

    @Test
    fun historyLimitIsDisclosedOnlyWhenTheRetainedHistoryStartsInsideThePeriod() {
        val now = instant("2026-11-14T12:00:00Z")
        val first = Instant.parse("2026-10-10T00:00:00Z").toEpochMilli()
        val full = List(ReadingRecapPolicy.HISTORY_SESSION_LIMIT) { index ->
            session("s$index", first + index * 3_600_000L, 60L)
        }

        val october = ReadingRecapPolicy.totals(full, month("2026-10"), now, ZoneOffset.UTC)
        val november = ReadingRecapPolicy.totals(full, month("2026-11"), now, ZoneOffset.UTC)
        val partial = ReadingRecapPolicy.totals(full.drop(1), month("2026-10"), now, ZoneOffset.UTC)

        assertTrue(october.historyMayBeIncomplete)
        assertFalse(november.historyMayBeIncomplete)
        assertFalse(partial.historyMayBeIncomplete)
        assertTrue(ReadingRecapFormat.historyDisclosure(october).startsWith("This device keeps your most recent"))
    }

    @Test
    fun resolvedMetadataKeepsMissingBooksAndSkipsPodcasts() {
        val now = instant("2026-11-14T12:00:00Z")
        val sessions = listOf(
            session("a", instant("2026-11-02T12:00:00Z"), 900L, AppMediaType.AUDIOBOOK, "LOCAL:a"),
            session("b", instant("2026-11-03T12:00:00Z"), 1_200L, AppMediaType.EBOOK, "LOCAL:missing"),
            session("c", instant("2026-11-04T12:00:00Z"), 600L, AppMediaType.EBOOK, "LOCAL:c"),
            session("p", instant("2026-11-05T12:00:00Z"), 5_000L, AppMediaType.PODCAST, "LOCAL:podcast"),
        )
        val totals = ReadingRecapPolicy.totals(sessions, null, now, ZoneOffset.UTC)

        val recap = ReadingRecapPolicy.resolve(
            totals,
            mapOf(
                "LOCAL:a" to book("a", author = "N. K. Jemisin", narrator = "Robin Miles"),
                "LOCAL:c" to book("c", author = "N. K. Jemisin", narrator = "Ebook Narrator"),
            ),
        )

        assertEquals(listOf("LOCAL:a", "LOCAL:c"), recap.topBooks.map(RecapBookEntry::bookKey))
        assertEquals(InsightNamedEntry("N. K. Jemisin", 1_500L), recap.topAuthor)
        assertEquals(InsightNamedEntry("Robin Miles", 900L), recap.topNarrator)
        assertEquals(7_700L, recap.totalSeconds)
    }

    @Test
    fun emptyStateDistinguishesTheCurrentAndPastPeriods() {
        val now = instant("2026-11-14T12:00:00Z")
        val sessions = listOf(session("old", instant("2026-08-20T12:00:00Z"), 600L))

        val current = ReadingRecapPolicy.totals(sessions, null, now, ZoneOffset.UTC)
        val past = ReadingRecapPolicy.totals(sessions, month("2026-09"), now, ZoneOffset.UTC)

        assertTrue(current.isEmpty)
        assertEquals("Nothing on the record for November 2026", ReadingRecapFormat.emptyTitle(current, Locale.US))
        assertEquals(
            "Finish a listening or reading session this month and it will appear here.",
            ReadingRecapFormat.emptyBody(current),
        )
        assertTrue(past.isEmpty)
        assertEquals(
            "No listening or reading sessions were saved on this device during that month.",
            ReadingRecapFormat.emptyBody(past),
        )
    }

    @Test
    fun shareTextSummarizesTheRecap() {
        val now = instant("2026-11-14T12:00:00Z")
        val sessions = listOf(
            session("a", instant("2026-11-07T12:00:00Z"), 5_400L, AppMediaType.AUDIOBOOK, "LOCAL:a", 0.5f, 1f),
            session("b", instant("2026-11-08T12:00:00Z"), 1_800L, AppMediaType.EBOOK, "LOCAL:b"),
        )
        val recap = ReadingRecapPolicy.resolve(
            ReadingRecapPolicy.totals(sessions, null, now, ZoneOffset.UTC),
            mapOf("LOCAL:a" to book("a", title = "The Fifth Season", author = "N. K. Jemisin")),
        )

        assertEquals(
            listOf(
                "My November 2026 with books",
                "2h 0m in total: 1h 30m listening, 30m reading",
                "2 active days across 2 sessions",
                "Busiest day: Saturday, November 7 (1h 30m)",
                "Most time with: The Fifth Season",
                "Top author: N. K. Jemisin",
            ).joinToString("\n"),
            ReadingRecapFormat.shareText(recap, Locale.US),
        )
    }

    private fun month(value: String) = ReadingRecapPeriod.Month(YearMonth.parse(value))

    private fun instant(value: String): Long = Instant.parse(value).toEpochMilli()

    private fun local(value: String, zone: ZoneId): Long =
        LocalDateTime.parse(value).atZone(zone).toInstant().toEpochMilli()

    private fun book(
        id: String,
        title: String = id,
        author: String? = null,
        narrator: String? = null,
    ) = Book(id = id, title = title, author = author, narrator = narrator, source = BookSource.LOCAL)

    private fun session(
        id: String,
        endMs: Long,
        seconds: Long,
        mediaType: AppMediaType = AppMediaType.EBOOK,
        bookKey: String = "LOCAL:book",
        startProgress: Float? = null,
        endProgress: Float? = null,
    ) = HistorySession(
        id = id,
        bookId = bookKey.substringAfter(':'),
        bookKey = bookKey,
        source = BookSource.LOCAL,
        mediaType = mediaType,
        startTimeMs = endMs - seconds.coerceAtLeast(0L) * 1_000L,
        endTimeMs = endMs,
        activeDurationSeconds = seconds,
        startProgress = startProgress,
        endProgress = endProgress,
    )
}
