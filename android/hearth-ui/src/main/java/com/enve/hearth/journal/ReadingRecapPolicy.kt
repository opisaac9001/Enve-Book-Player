package com.enve.hearth.journal

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.HistorySession
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

sealed interface ReadingRecapPeriod {
    val start: LocalDate
    val endExclusive: LocalDate
    fun previous(): ReadingRecapPeriod
    fun next(): ReadingRecapPeriod
    fun containing(day: LocalDate): ReadingRecapPeriod

    operator fun contains(day: LocalDate): Boolean = !day.isBefore(start) && day.isBefore(endExclusive)

    data class Month(val month: YearMonth) : ReadingRecapPeriod {
        override val start: LocalDate get() = month.atDay(1)
        override val endExclusive: LocalDate get() = month.plusMonths(1).atDay(1)
        override fun previous() = Month(month.minusMonths(1))
        override fun next() = Month(month.plusMonths(1))
        override fun containing(day: LocalDate) = Month(YearMonth.from(day))
    }

    data class Year(val year: Int) : ReadingRecapPeriod {
        override val start: LocalDate get() = LocalDate.of(year, 1, 1)
        override val endExclusive: LocalDate get() = LocalDate.of(year + 1, 1, 1)
        override fun previous() = Year(year - 1)
        override fun next() = Year(year + 1)
        override fun containing(day: LocalDate) = Year(day.year)
    }
}

data class RecapBookTotal(
    val bookKey: String,
    val mediaType: AppMediaType,
    val seconds: Long,
)

data class RecapBookEntry(
    val bookKey: String,
    val book: Book?,
    val seconds: Long,
)

data class RecapDay(
    val date: LocalDate,
    val seconds: Long,
)

data class ReadingRecap(
    val period: ReadingRecapPeriod,
    val totalSeconds: Long = 0L,
    val listeningSeconds: Long = 0L,
    val readingSeconds: Long = 0L,
    val sessions: Int = 0,
    val activeDays: Int = 0,
    val pagesRead: Int = 0,
    val busiestDay: RecapDay? = null,
    val bookTotals: List<RecapBookTotal> = emptyList(),
    val topBooks: List<RecapBookEntry> = emptyList(),
    val topAuthor: InsightNamedEntry? = null,
    val topNarrator: InsightNamedEntry? = null,
    val canGoBack: Boolean = false,
    val canGoForward: Boolean = false,
    val historyMayBeIncomplete: Boolean = false,
) {
    val isEmpty: Boolean get() = sessions == 0
}

internal object ReadingRecapPolicy {
    const val HISTORY_SESSION_LIMIT = 1_000
    private const val TOP_BOOKS = 5

    fun totals(
        sessions: List<HistorySession>,
        requested: ReadingRecapPeriod?,
        nowMs: Long,
        zone: ZoneId,
    ): ReadingRecap {
        val today = ReadingHistory.day(nowMs, zone)
        val dated = ReadingHistory.validSessions(sessions, nowMs)
            .map { it to ReadingHistory.day(it.endTimeMs, zone) }
        val earliest = dated.minOfOrNull { it.second } ?: today
        val period = clamp(requested ?: ReadingRecapPeriod.Month(YearMonth.from(today)), earliest, today)
        val inPeriod = dated.filter { (_, day) -> day in period }
        val periodSessions = inPeriod.map { it.first }
        val dailySeconds = inPeriod
            .groupBy(keySelector = { it.second }, valueTransform = { it.first.activeDurationSeconds })
            .mapValues { (_, seconds) -> seconds.sum() }
        val busiestDay = dailySeconds.entries
            .sortedWith(compareByDescending<Map.Entry<LocalDate, Long>> { it.value }.thenBy { it.key })
            .firstOrNull()
            ?.let { RecapDay(it.key, it.value) }
        val bookTotals = periodSessions
            .groupBy(HistorySession::bookKey)
            .map { (key, entries) ->
                RecapBookTotal(key, entries.first().mediaType, entries.sumOf(HistorySession::activeDurationSeconds))
            }
            .sortedWith(compareByDescending<RecapBookTotal>(RecapBookTotal::seconds).thenBy(RecapBookTotal::bookKey))

        return ReadingRecap(
            period = period,
            totalSeconds = periodSessions.sumOf(HistorySession::activeDurationSeconds),
            listeningSeconds = periodSessions
                .filter { it.mediaType == AppMediaType.AUDIOBOOK || it.mediaType == AppMediaType.PODCAST }
                .sumOf(HistorySession::activeDurationSeconds),
            readingSeconds = periodSessions
                .filter { it.mediaType == AppMediaType.EBOOK }
                .sumOf(HistorySession::activeDurationSeconds),
            sessions = periodSessions.size,
            activeDays = dailySeconds.size,
            pagesRead = periodSessions.sumOf { (it.pagesRead ?: 0).coerceAtLeast(0) },
            busiestDay = busiestDay,
            bookTotals = bookTotals,
            canGoBack = earliest.isBefore(period.start),
            canGoForward = !period.endExclusive.isAfter(today),
            historyMayBeIncomplete = sessions.size >= HISTORY_SESSION_LIMIT && !earliest.isBefore(period.start),
        )
    }

    fun lookupKeys(recap: ReadingRecap): List<String> =
        recap.bookTotals.filter { it.mediaType != AppMediaType.PODCAST }.map(RecapBookTotal::bookKey)

    fun resolve(recap: ReadingRecap, books: Map<String, Book>): ReadingRecap {
        val bookTotals = recap.bookTotals.filter { it.mediaType != AppMediaType.PODCAST && it.bookKey in books }
            .sortedWith(compareByDescending<RecapBookTotal> { it.seconds }
                .thenBy { books.getValue(it.bookKey).title }.thenBy { it.bookKey })
        return recap.copy(
            topBooks = bookTotals.take(TOP_BOOKS).map { RecapBookEntry(it.bookKey, books[it.bookKey], it.seconds) },
            topAuthor = topName(bookTotals, books, Book::author),
            topNarrator = topName(bookTotals.filter { it.mediaType == AppMediaType.AUDIOBOOK }, books, Book::narrator),
        )
    }

    fun clamp(period: ReadingRecapPeriod, earliest: LocalDate, today: LocalDate): ReadingRecapPeriod = when {
        period.start.isAfter(today) -> period.containing(today)
        !period.endExclusive.isAfter(earliest) -> period.containing(earliest)
        else -> period
    }

    private fun topName(
        totals: List<RecapBookTotal>,
        books: Map<String, Book>,
        value: (Book) -> String?,
    ): InsightNamedEntry? {
        val byName = mutableMapOf<String, Long>()
        totals.forEach { total ->
            val name = books[total.bookKey]?.let(value)?.trim()?.takeIf(String::isNotEmpty) ?: return@forEach
            byName[name] = (byName[name] ?: 0L) + total.seconds
        }
        return byName.entries
            .sortedWith(compareByDescending<Map.Entry<String, Long>> { it.value }.thenBy { it.key })
            .firstOrNull()
            ?.let { InsightNamedEntry(it.key, it.value) }
    }
}

internal object ReadingRecapFormat {
    fun title(period: ReadingRecapPeriod, locale: Locale): String = when (period) {
        is ReadingRecapPeriod.Month -> period.month.format(DateTimeFormatter.ofPattern("LLLL yyyy", locale))
        is ReadingRecapPeriod.Year -> period.year.toString()
    }

    fun unit(period: ReadingRecapPeriod): String = when (period) {
        is ReadingRecapPeriod.Month -> "month"
        is ReadingRecapPeriod.Year -> "year"
    }

    fun duration(seconds: Long): String {
        val hours = seconds / 3_600L
        val minutes = (seconds % 3_600L) / 60L
        return when {
            hours > 0L -> "${hours}h ${minutes}m"
            minutes == 0L && seconds > 0L -> "<1m"
            else -> "${minutes}m"
        }
    }

    fun day(date: LocalDate, locale: Locale): String =
        date.format(DateTimeFormatter.ofPattern("EEEE, MMMM d", locale))

    fun emptyTitle(recap: ReadingRecap, locale: Locale): String =
        "Nothing on the record for ${title(recap.period, locale)}"

    fun emptyBody(recap: ReadingRecap): String =
        if (recap.canGoForward) {
            "No listening or reading sessions were saved on this device during that ${unit(recap.period)}."
        } else {
            "Finish a listening or reading session this ${unit(recap.period)} and it will appear here."
        }

    fun historyDisclosure(recap: ReadingRecap): String =
        if (recap.historyMayBeIncomplete) {
            "This device keeps your most recent ${"%,d".format(ReadingRecapPolicy.HISTORY_SESSION_LIMIT)} sessions, so earlier activity in this ${unit(recap.period)} may be missing."
        } else {
            "Built from the listening and reading history saved on this device. Finished-book counts are not included because completion dates are not recorded."
        }

    fun bookTitle(entry: RecapBookEntry): String =
        entry.book?.title?.trim()?.takeIf(String::isNotEmpty) ?: "A book no longer in your library"

    fun shareText(recap: ReadingRecap, locale: Locale): String = buildList {
        add("My ${title(recap.period, locale)} with books")
        add("${duration(recap.totalSeconds)} in total: ${duration(recap.listeningSeconds)} listening, ${duration(recap.readingSeconds)} reading")
        add("${recap.activeDays} active ${if (recap.activeDays == 1) "day" else "days"} across ${recap.sessions} ${if (recap.sessions == 1) "session" else "sessions"}")
        recap.busiestDay?.let { add("Busiest day: ${day(it.date, locale)} (${duration(it.seconds)})") }
        recap.topBooks.firstOrNull()?.let { add("Most time with: ${bookTitle(it)}") }
        recap.topAuthor?.let { add("Top author: ${it.name}") }

    }.joinToString("\n")
}
