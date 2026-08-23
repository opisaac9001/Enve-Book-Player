package com.enve.hearth.journal

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.HistorySession
import com.enve.engine.library.LibraryFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.stateIn
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.TextStyle
import java.time.temporal.TemporalAdjusters
import java.util.Locale
import javax.inject.Inject

data class InsightBookEntry(
    val book: Book,
    val seconds: Long,
)

data class InsightNamedEntry(
    val name: String,
    val seconds: Long,
)

data class YearReview(
    val year: Int,
    val totalSeconds: Long = 0,
    val listeningSeconds: Long = 0,
    val readingSeconds: Long = 0,
    val pagesRead: Int = 0,
    val sessions: Int = 0,
    val activeDays: Int = 0,
    val booksFinished: Int = 0,
    val favoriteMonth: String? = null,
    val topBook: InsightBookEntry? = null,
    val topAuthor: InsightNamedEntry? = null,
    val topNarrator: InsightNamedEntry? = null,
)

data class JournalInsights(
    val thisWeekSeconds: Long = 0,
    val lastWeekSeconds: Long = 0,
    val currentStreak: Int = 0,
    val longestStreak: Int = 0,
    val favoriteWeekday: String? = null,
    val topBooks: List<InsightBookEntry> = emptyList(),
    val topAuthors: List<InsightNamedEntry> = emptyList(),
    val topNarrators: List<InsightNamedEntry> = emptyList(),
    val availableYears: List<Int> = emptyList(),
    val yearReview: YearReview = YearReview(Instant.now().atZone(ZoneId.systemDefault()).year),
)

@HiltViewModel
class HearthInsightsViewModel @Inject constructor(
    library: LibraryFacade,
) : ViewModel() {
    private val selectedYear = MutableStateFlow(Instant.now().atZone(ZoneId.systemDefault()).year)

    val insights: StateFlow<JournalInsights> = combine(
        library.allBooks,
        library.historySessions,
        selectedYear,
    ) { books, sessions, year ->
        JournalInsightsPolicy.snapshot(books, sessions, year)
    }
        .flowOn(Dispatchers.Default)
        .stateIn(
            viewModelScope,
            SharingStarted.WhileSubscribed(5_000),
            JournalInsights(
                availableYears = listOf(selectedYear.value),
                yearReview = YearReview(selectedYear.value),
            ),
        )

    fun selectYear(year: Int) {
        selectedYear.value = year
    }
}

internal object JournalInsightsPolicy {
    fun snapshot(
        books: List<Book>,
        sessions: List<HistorySession>,
        selectedYear: Int,
        nowMs: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): JournalInsights {
        val now = Instant.ofEpochMilli(nowMs)
        val today = now.atZone(zone).toLocalDate()
        val validSessions = sessions
            .asSequence()
            .distinctBy(HistorySession::id)
            .filter { it.activeDurationSeconds > 0L && it.endTimeMs <= nowMs }
            .toList()
        val weekStart = today.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
        val weekStartMs = weekStart.atStartOfDay(zone).toInstant().toEpochMilli()
        val lastWeekStartMs = weekStart.minusWeeks(1).atStartOfDay(zone).toInstant().toEpochMilli()
        val thisWeek = validSessions.filter { it.endTimeMs in weekStartMs..nowMs }
        val lastWeek = validSessions.filter { it.endTimeMs in lastWeekStartMs until weekStartMs }
        val activeDays = validSessions.mapTo(mutableSetOf()) { day(it.endTimeMs, zone) }

        val yearStart = LocalDate.of(selectedYear, 1, 1)
        val nextYearStart = yearStart.plusYears(1)
        val yearStartMs = yearStart.atStartOfDay(zone).toInstant().toEpochMilli()
        val nextYearStartMs = nextYearStart.atStartOfDay(zone).toInstant().toEpochMilli()
        val annualSessions = validSessions.filter { it.endTimeMs in yearStartMs until nextYearStartMs }
        val annualDays = annualSessions.mapTo(mutableSetOf()) { day(it.endTimeMs, zone) }

        val bookLookup = BookLookup(books)
        val topBooks = topBooks(validSessions, bookLookup)
        val annualTopBooks = topBooks(annualSessions, bookLookup)
        val topAuthors = topNames(validSessions, bookLookup, Book::author)
        val annualTopAuthors = topNames(annualSessions, bookLookup, Book::author)
        val topNarrators = topNames(validSessions, bookLookup, Book::narrator)
        val annualTopNarrators = topNames(annualSessions, bookLookup, Book::narrator)
        val availableYears = buildSet {
            add(today.year)
            validSessions.forEach { add(day(it.endTimeMs, zone).year) }
            books.asSequence()
                .filter { it.isFinished && it.lastReadTime in 1..nowMs }
                .forEach { add(day(it.lastReadTime, zone).year) }
        }.sortedDescending()
        val booksFinished = books.count {
                it.mediaType != AppMediaType.PODCAST &&
                it.isFinished &&
                it.lastReadTime in yearStartMs until nextYearStartMs &&
                it.lastReadTime <= nowMs
        }

        return JournalInsights(
            thisWeekSeconds = duration(thisWeek),
            lastWeekSeconds = duration(lastWeek),
            currentStreak = currentStreak(activeDays, today),
            longestStreak = longestStreak(activeDays),
            favoriteWeekday = favoriteWeekday(validSessions, zone),
            topBooks = topBooks.take(8),
            topAuthors = topAuthors.take(8),
            topNarrators = topNarrators.take(8),
            availableYears = availableYears,
            yearReview = YearReview(
                year = selectedYear,
                totalSeconds = duration(annualSessions),
                listeningSeconds = duration(annualSessions.filter {
                    it.mediaType == AppMediaType.AUDIOBOOK || it.mediaType == AppMediaType.PODCAST
                }),
                readingSeconds = duration(annualSessions.filter { it.mediaType == AppMediaType.EBOOK }),
                pagesRead = annualSessions.sumOf { it.pagesRead ?: 0 },
                sessions = annualSessions.size,
                activeDays = annualDays.size,
                booksFinished = booksFinished,
                favoriteMonth = favoriteMonth(annualSessions, zone),
                topBook = annualTopBooks.firstOrNull(),
                topAuthor = annualTopAuthors.firstOrNull(),
                topNarrator = annualTopNarrators.firstOrNull(),
            ),
        )
    }

    private fun duration(sessions: List<HistorySession>): Long =
        sessions.sumOf(HistorySession::activeDurationSeconds)

    private fun day(epochMs: Long, zone: ZoneId): LocalDate =
        Instant.ofEpochMilli(epochMs).atZone(zone).toLocalDate()

    private fun currentStreak(activeDays: Set<LocalDate>, today: LocalDate): Int {
        var cursor = when {
            today in activeDays -> today
            today.minusDays(1) in activeDays -> today.minusDays(1)
            else -> return 0
        }
        var count = 0
        while (cursor in activeDays) {
            count += 1
            cursor = cursor.minusDays(1)
        }
        return count
    }

    private fun longestStreak(activeDays: Set<LocalDate>): Int {
        var longest = 0
        var run = 0
        var previous: LocalDate? = null
        activeDays.sorted().forEach { current ->
            run = if (previous?.plusDays(1) == current) run + 1 else 1
            longest = maxOf(longest, run)
            previous = current
        }
        return longest
    }

    private fun favoriteWeekday(sessions: List<HistorySession>, zone: ZoneId): String? {
        val totals = sessions
            .groupBy { day(it.endTimeMs, zone).dayOfWeek }
            .mapValues { (_, entries) -> duration(entries) }
        return totals.maxByOrNull { it.value }?.key
            ?.getDisplayName(TextStyle.FULL, Locale.getDefault())
    }

    private fun favoriteMonth(sessions: List<HistorySession>, zone: ZoneId): String? {
        val totals = sessions
            .groupBy { day(it.endTimeMs, zone).month }
            .mapValues { (_, entries) -> duration(entries) }
        return totals.maxByOrNull { it.value }?.key
            ?.getDisplayName(TextStyle.FULL, Locale.getDefault())
    }

    private fun topBooks(
        sessions: List<HistorySession>,
        lookup: BookLookup,
    ): List<InsightBookEntry> {
        val resolved = sessions.mapNotNull { session ->
            lookup.resolve(session)?.let { it to session.activeDurationSeconds }
        }
        return resolved
            .groupBy(keySelector = { it.first.uniqueKey }, valueTransform = { it })
            .mapNotNull { (_, entries) ->
                entries.firstOrNull()?.first?.let { book ->
                    InsightBookEntry(book, entries.sumOf { it.second })
                }
            }
            .sortedWith(compareByDescending<InsightBookEntry>(InsightBookEntry::seconds).thenBy { it.book.title })
    }

    private fun topNames(
        sessions: List<HistorySession>,
        lookup: BookLookup,
        value: (Book) -> String?,
    ): List<InsightNamedEntry> {
        val totals = mutableMapOf<String, Long>()
        sessions.forEach { session ->
            val name = lookup.resolve(session)
                ?.let(value)
                ?.trim()
                ?.takeIf(String::isNotEmpty)
                ?: return@forEach
            totals[name] = (totals[name] ?: 0L) + session.activeDurationSeconds
        }
        return totals.map { InsightNamedEntry(it.key, it.value) }
            .sortedWith(compareByDescending<InsightNamedEntry>(InsightNamedEntry::seconds).thenBy(InsightNamedEntry::name))
    }

    private class BookLookup(books: List<Book>) {
        private val byKey = books.associateBy(Book::uniqueKey)
        private val byId = books
            .groupBy(Book::id)
            .mapNotNull { (id, matches) -> matches.singleOrNull()?.let { id to it } }
            .toMap()

        fun resolve(session: HistorySession): Book? =
            byKey[session.bookKey] ?: byId[session.bookId]
    }
}
