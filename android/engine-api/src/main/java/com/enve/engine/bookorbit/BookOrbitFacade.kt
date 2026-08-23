package com.enve.engine.bookorbit

import com.enve.core.data.model.Book
import kotlinx.coroutines.flow.Flow

data class BookOrbitAccount(
    val connectionId: String,
    val name: String,
)

data class BookOrbitSummary(
    val trackedBooks: Int,
    val startedBooks: Int,
    val inProgressBooks: Int,
    val completedBooks: Int,
    val meanProgressPercent: Double,
)

data class BookOrbitStreak(
    val currentStreak: Int,
    val longestStreak: Int,
    val lastSevenDays: List<Boolean>,
)

data class BookOrbitGoal(
    val goalBooks: Int,
    val completedBooks: Int,
    val year: Int,
)

data class BookOrbitLibraryOverview(
    val totalBooks: Int,
    val totalAuthors: Int,
    val totalSeries: Int,
    val totalStorageBytes: Long,
    val booksAddedThisYear: Int,
)

data class BookOrbitYearProjection(
    val projectedBooks: Int,
    val projectedHours: Int,
    val booksCompletedYtd: Int,
    val daysRemaining: Int,
    val trend: String?,
)

data class BookOrbitRhythm(
    val consistencyPercent: Double,
    val averageSecondsPerDay: Long,
    val activeDays: Int,
    val totalDays: Int,
)

data class BookOrbitChallenge(
    val title: String,
    val description: String,
    val progress: Double,
    val target: Double,
    val completed: Boolean,
)

data class BookOrbitScoreFacet(
    val label: String,
    val score: Double,
)

data class BookOrbitDiversity(
    val score: Double,
    val label: String,
    val facets: List<BookOrbitScoreFacet>,
    val booksAnalyzed: Int,
)

data class BookOrbitReadingDna(
    val archetype: String,
    val facets: List<BookOrbitScoreFacet>,
    val booksAnalyzed: Int,
)

data class BookOrbitDailyHighlight(
    val bookId: Int,
    val bookTitle: String?,
    val chapterTitle: String?,
    val text: String,
    val note: String?,
)

data class BookOrbitDailyPoint(
    val day: String,
    val readingSeconds: Long,
    val eventsCount: Int,
)

data class BookOrbitSourceSlice(
    val bucket: String,
    val label: String,
    val readingSeconds: Long,
)

data class BookOrbitHourSlice(
    val hour: Int,
    val readingSeconds: Long,
)

data class BookOrbitWeekdaySlice(
    val dayOfWeek: Int,
    val label: String,
    val readingSeconds: Long,
)

data class BookOrbitGenreSlice(
    val genre: String,
    val readingSeconds: Long,
)

data class BookOrbitMonthlyCount(
    val year: Int,
    val month: Int,
    val count: Int,
)

data class BookOrbitFunnelStage(
    val label: String,
    val count: Int,
)

data class BookOrbitFunnel(
    val stages: List<BookOrbitFunnelStage>,
    val previousCompleted: Int?,
)

data class BookOrbitCompletionLatency(
    val totalCompletions: Int,
    val medianDays: Double?,
    val percentile90Days: Double?,
)

data class BookOrbitInsights(
    val days: Int,
    val summary: BookOrbitSummary?,
    val streak: BookOrbitStreak?,
    val goal: BookOrbitGoal?,
    val library: BookOrbitLibraryOverview?,
    val projection: BookOrbitYearProjection?,
    val rhythm: BookOrbitRhythm?,
    val challenge: BookOrbitChallenge?,
    val diversity: BookOrbitDiversity?,
    val readingDna: BookOrbitReadingDna?,
    val highlightOfTheDay: BookOrbitDailyHighlight?,
    val dailyReading: List<BookOrbitDailyPoint>,
    val heatmap: List<BookOrbitDailyPoint>,
    val sources: List<BookOrbitSourceSlice>,
    val peakHours: List<BookOrbitHourSlice>,
    val favoriteDays: List<BookOrbitWeekdaySlice>,
    val genres: List<BookOrbitGenreSlice>,
    val completions: List<BookOrbitMonthlyCount>,
    val funnel: BookOrbitFunnel?,
    val completionLatency: BookOrbitCompletionLatency?,
) {
    val totalWindowSeconds: Long get() = dailyReading.sumOf(BookOrbitDailyPoint::readingSeconds)
}

data class BookOrbitAchievement(
    val key: String,
    val name: String,
    val description: String,
    val rarity: String,
    val earned: Boolean,
    val awardedAtMs: Long?,
    val currentProgress: Double?,
    val threshold: Double?,
)

data class BookOrbitAchievementCategory(
    val key: String,
    val label: String,
    val earnedCount: Int,
    val totalCount: Int,
    val achievements: List<BookOrbitAchievement>,
)

data class BookOrbitAchievements(
    val categories: List<BookOrbitAchievementCategory>,
    val totalEarned: Int,
    val totalAvailable: Int,
)

data class BookOrbitRelatedBook(
    val bookId: Int,
    val title: String,
    val authors: String?,
    val coverUrl: String?,
    val seriesLabel: String?,
)

data class BookOrbitRelated(
    val recommendations: List<BookOrbitRelatedBook>,
    val seriesBooks: List<BookOrbitRelatedBook>,
    val authorBooks: List<BookOrbitRelatedBook>,
) {
    val isEmpty: Boolean
        get() = recommendations.isEmpty() && seriesBooks.isEmpty() && authorBooks.isEmpty()
}

data class BookOrbitHighlightQuery(
    val page: Int = 1,
    val trashed: Boolean = false,
    val search: String = "",
    val bookId: Int? = null,
    val colors: List<String> = emptyList(),
    val origins: List<String> = emptyList(),
    val notesOnly: Boolean = false,
)

data class BookOrbitHighlight(
    val id: Int,
    val bookId: Int,
    val bookTitle: String?,
    val author: String?,
    val text: String,
    val note: String?,
    val colorHex: String,
    val chapterTitle: String?,
    val origin: String?,
    val createdAtMs: Long?,
    val trashed: Boolean,
)

data class BookOrbitHighlightBookFacet(
    val bookId: Int,
    val title: String,
    val author: String?,
    val count: Int,
)

data class BookOrbitHighlightPage(
    val items: List<BookOrbitHighlight>,
    val total: Int,
    val page: Int,
    val hasMore: Boolean,
    val books: Int,
    val withNotes: Int,
    val origins: List<BookOrbitOriginCount>,
)

data class BookOrbitOriginCount(
    val origin: String,
    val count: Int,
)

enum class BookOrbitExportFormat(val wire: String, val mimeType: String) {
    MARKDOWN("md", "text/markdown"),
    CSV("csv", "text/csv"),
    JSON("json", "application/json"),
}

data class BookOrbitHighlightExport(
    val filename: String,
    val content: String,
    val format: BookOrbitExportFormat,
)

interface BookOrbitFacade {
    val accounts: Flow<List<BookOrbitAccount>>

    suspend fun insights(connectionId: String, days: Int): BookOrbitInsights?

    suspend fun achievements(connectionId: String): BookOrbitAchievements?

    suspend fun related(book: Book): BookOrbitRelated?

    suspend fun highlights(connectionId: String, query: BookOrbitHighlightQuery): BookOrbitHighlightPage?

    suspend fun highlightBooks(connectionId: String, trashed: Boolean, search: String): List<BookOrbitHighlightBookFacet>

    suspend fun trashHighlights(connectionId: String, ids: List<Int>): Int

    suspend fun restoreHighlights(connectionId: String, ids: List<Int>): Int

    suspend fun deleteHighlight(connectionId: String, id: Int): Boolean

    suspend fun exportHighlights(
        connectionId: String,
        query: BookOrbitHighlightQuery,
        format: BookOrbitExportFormat,
    ): BookOrbitHighlightExport?

    suspend fun openBook(connectionId: String, bookId: Int): Book?
}
