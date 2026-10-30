package com.enve.app.data.servertools

import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.*
import com.enve.core.data.util.runSuspendCatching
import com.enve.engine.servertools.ServerFeatureUnsupportedException
import retrofit2.HttpException
import javax.inject.Inject
import javax.inject.Singleton
import retrofit2.Response

data class GrimmoryReadingStats(
    val year: Int,
    val currentStreak: Int? = null,
    val longestStreak: Int? = null,
    val totalReadingDays: Int? = null,
    val totalAudiobooks: Int? = null,
    val completedAudiobooks: Int? = null,
    val inProgressAudiobooks: Int? = null,
    val streakDays: List<GrimmoryStreakDayDto> = emptyList(),
    val readingDays: List<GrimmoryActivityDayDto> = emptyList(),
    val readingPeakHours: List<GrimmoryPeakHourDto> = emptyList(),
    val readingFavoriteDays: List<GrimmoryFavoriteDayDto> = emptyList(),
    val readingGenres: List<GrimmoryGenreStatDto> = emptyList(),
    val completionTimeline: List<GrimmoryCompletionMonthDto> = emptyList(),
    val completionHeatmap: List<GrimmoryCompletionHeatmapMonthDto> = emptyList(),
    val pageTurners: List<GrimmoryPageTurnerDto> = emptyList(),
    val distributions: GrimmoryBookDistributionsDto? = null,
    val readingSpeed: List<GrimmoryReadingSpeedDayDto> = emptyList(),
    val readingSessions: List<GrimmorySessionPointDto> = emptyList(),
    val bookTimeline: List<GrimmoryBookTimelineEntryDto> = emptyList(),
    val completionRace: List<GrimmoryCompletionRacePointDto> = emptyList(),
    val listeningTrend: List<GrimmoryListeningWeekDto> = emptyList(),
    val listeningInProgress: List<GrimmoryAudiobookProgressDto> = emptyList(),
    val listeningPace: List<GrimmoryListeningMonthDto> = emptyList(),
    val listeningFunnel: GrimmoryListeningFunnelDto? = null,
    val listeningPeakHours: List<GrimmoryPeakHourDto> = emptyList(),
    val listeningFavoriteDays: List<GrimmoryFavoriteDayDto> = emptyList(),
    val listeningGenres: List<GrimmoryGenreStatDto> = emptyList(),
    val listeningAuthors: List<GrimmoryAuthorStatDto> = emptyList(),
    val listeningSessions: List<GrimmorySessionPointDto> = emptyList(),
    val longestAudiobooks: List<GrimmoryLongestAudiobookDto> = emptyList(),
) {
    val isEmpty: Boolean
        get() = listOfNotNull(
            currentStreak,
            longestStreak,
            totalReadingDays,
            totalAudiobooks,
            completedAudiobooks,
            inProgressAudiobooks,
        ).isEmpty() && listOf(
            readingDays,
            readingPeakHours,
            readingFavoriteDays,
            readingGenres,
            completionTimeline,
            completionHeatmap,
            pageTurners,
            readingSpeed,
            readingSessions,
            bookTimeline,
            completionRace,
            listeningTrend,
            listeningInProgress,
            listeningPace,
            listeningPeakHours,
            listeningFavoriteDays,
            listeningGenres,
            listeningAuthors,
            listeningSessions,
            longestAudiobooks,
        ).all(List<*>::isEmpty) && distributions == null && listeningFunnel == null
}

data class GrimmoryNote(
    val id: String,
    val bookTitle: String?,
    val author: String?,
    val chapterTitle: String?,
    val text: String,
    val note: String?,
    val createdAt: String?,
)

@Singleton
class GrimmoryToolsRepository @Inject constructor(
    private val api: GrimmoryApi,
) {
    suspend fun stats(): Result<GrimmoryReadingStats?> = runSuspendCatching {
        val requests = OptionalRequests()
        val year = java.time.LocalDate.now().year
        val streak = requests.get { api.getReadingStreak() }
        val listening = requests.get { api.getListeningCompletion() }
        val stats = GrimmoryReadingStats(
            year = year,
            currentStreak = streak?.currentStreak,
            longestStreak = streak?.longestStreak,
            totalReadingDays = streak?.totalReadingDays,
            totalAudiobooks = listening?.totalAudiobooks,
            completedAudiobooks = listening?.completed,
            inProgressAudiobooks = listening?.inProgressCount,
            streakDays = streak?.last52Weeks.orEmpty(),
            readingDays = requests.list { api.getReadingHeatmap(year) },
            readingPeakHours = requests.list { api.getReadingPeakHours(year) },
            readingFavoriteDays = requests.list { api.getReadingFavoriteDays(year) },
            readingGenres = requests.list { api.getReadingGenres() },
            completionTimeline = requests.list { api.getCompletionTimeline(year) },
            completionHeatmap = requests.list { api.getCompletionHeatmap() },
            pageTurners = requests.list { api.getPageTurners() },
            distributions = requests.get { api.getBookDistributions() },
            readingSpeed = requests.list { api.getReadingSpeed(year) },
            readingSessions = requests.list { api.getReadingSessionScatter(year) },
            bookTimeline = requests.list { api.getBookTimeline(year) },
            completionRace = requests.list { api.getCompletionRace(year) },
            listeningTrend = requests.list { api.getListeningTrend() },
            listeningInProgress = listening?.inProgress.orEmpty(),
            listeningPace = requests.list { api.getListeningPace() },
            listeningFunnel = requests.get { api.getListeningFunnel() },
            listeningPeakHours = requests.list { api.getListeningPeakHours(year) },
            listeningFavoriteDays = requests.list { api.getListeningFavoriteDays(year) },
            listeningGenres = requests.list { api.getListeningGenres() },
            listeningAuthors = requests.list { api.getListeningAuthors() },
            listeningSessions = requests.list { api.getListeningSessionScatter() },
            longestAudiobooks = requests.list { api.getLongestAudiobooks() },
        )
        requests.requireSupported()
        stats.takeUnless { it.isEmpty }
    }

    suspend fun notes(limit: Int): Result<List<GrimmoryNote>?> = runSuspendCatching {
        val requests = OptionalRequests()
        val books = requests.get { api.getNotebookBooks(page = 0, size = NOTEBOOK_BOOKS) }
        requests.requireSupported()
        val notebookBooks = books?.content.orEmpty()
        buildList {
            for (book in notebookBooks) {
                if (size >= limit) break
                val entries = requests.get { api.getNotebookEntries(book.bookId, page = 0, size = NOTEBOOK_ENTRIES) }
                    ?.content
                    .orEmpty()
                entries.forEach { entry ->
                    add(entry.toNote(book.bookTitle, book.authors?.joinToString(", ")))
                }
            }
        }
            .filter { it.text.isNotBlank() }
            .sortedByDescending { it.createdAt.orEmpty() }
            .take(limit)
    }

    suspend fun recommendedBookIds(bookId: String, limit: Int): Result<List<String>?> = runSuspendCatching {
        val response = api.getBookRecommendations(bookId, limit.coerceIn(1, 25))
        if (response.code() == 404) return@runSuspendCatching null
        if (!response.isSuccessful) error("Grimmory recommendations failed: HTTP ${response.code()}")
        response.body().orEmpty()
            .sortedByDescending { it.similarityScore }
            .mapNotNull { it.book?.id }
            .filterNot { it == bookId }
            .distinct()
    }

    private fun NotebookEntryDto.toNote(bookTitle: String?, author: String?): GrimmoryNote = GrimmoryNote(
        id = id,
        bookTitle = bookTitle?.takeIf { it.isNotBlank() },
        author = author?.takeIf { it.isNotBlank() },
        chapterTitle = chapterTitle?.takeIf { it.isNotBlank() },
        text = text?.takeIf { it.isNotBlank() } ?: note.orEmpty(),
        note = note?.takeIf { it.isNotBlank() && it != text },
        createdAt = createdAt,
    )

    private class OptionalRequests {
        private var supported = false

        suspend fun <T> get(request: suspend () -> Response<T>): T? {
            val response = request()
            if (response.code() in listOf(404, 405)) return null
            if (!response.isSuccessful) throw HttpException(response)
            supported = true
            return response.body().also {
                check(it != null || response.code() == 204) { "Grimmory reader feature returned no response body" }
            }
        }

        suspend fun <T> list(request: suspend () -> Response<List<T>>): List<T> = get(request).orEmpty()

        fun requireSupported() {
            if (!supported) throw ServerFeatureUnsupportedException()
        }
    }

    private companion object {
        const val NOTEBOOK_BOOKS = 6
        const val NOTEBOOK_ENTRIES = 10
    }
}
