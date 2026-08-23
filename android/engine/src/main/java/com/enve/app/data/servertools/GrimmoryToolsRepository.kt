package com.enve.app.data.servertools

import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.*
import kotlinx.coroutines.CancellationException
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
    suspend fun stats(): Result<GrimmoryReadingStats?> = runCatching {
        val year = java.time.LocalDate.now().year
        val streak = optional { api.getReadingStreak() }
        val listening = optional { api.getListeningCompletion() }
        GrimmoryReadingStats(
            year = year,
            currentStreak = streak?.currentStreak,
            longestStreak = streak?.longestStreak,
            totalReadingDays = streak?.totalReadingDays,
            totalAudiobooks = listening?.totalAudiobooks,
            completedAudiobooks = listening?.completed,
            inProgressAudiobooks = listening?.inProgressCount,
            streakDays = streak?.last52Weeks.orEmpty(),
            readingDays = optionalList { api.getReadingHeatmap(year) },
            readingPeakHours = optionalList { api.getReadingPeakHours(year) },
            readingFavoriteDays = optionalList { api.getReadingFavoriteDays(year) },
            readingGenres = optionalList { api.getReadingGenres() },
            completionTimeline = optionalList { api.getCompletionTimeline(year) },
            completionHeatmap = optionalList { api.getCompletionHeatmap() },
            pageTurners = optionalList { api.getPageTurners() },
            distributions = optional { api.getBookDistributions() },
            readingSpeed = optionalList { api.getReadingSpeed(year) },
            readingSessions = optionalList { api.getReadingSessionScatter(year) },
            bookTimeline = optionalList { api.getBookTimeline(year) },
            completionRace = optionalList { api.getCompletionRace(year) },
            listeningTrend = optionalList { api.getListeningTrend() },
            listeningInProgress = listening?.inProgress.orEmpty(),
            listeningPace = optionalList { api.getListeningPace() },
            listeningFunnel = optional { api.getListeningFunnel() },
            listeningPeakHours = optionalList { api.getListeningPeakHours(year) },
            listeningFavoriteDays = optionalList { api.getListeningFavoriteDays(year) },
            listeningGenres = optionalList { api.getListeningGenres() },
            listeningAuthors = optionalList { api.getListeningAuthors() },
            listeningSessions = optionalList { api.getListeningSessionScatter() },
            longestAudiobooks = optionalList { api.getLongestAudiobooks() },
        ).takeUnless { it.isEmpty }
    }

    suspend fun notes(limit: Int): Result<List<GrimmoryNote>?> = runCatching {
        val booksResponse = api.getNotebookBooks(page = 0, size = NOTEBOOK_BOOKS)
        if (booksResponse.code() == 404) return@runCatching null
        if (!booksResponse.isSuccessful) error("Grimmory notebook failed: HTTP ${booksResponse.code()}")
        val books = booksResponse.body()?.content.orEmpty()
        buildList {
            for (book in books) {
                if (size >= limit) break
                val entries = optional { api.getNotebookEntries(book.bookId, page = 0, size = NOTEBOOK_ENTRIES) }
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

    suspend fun recommendedBookIds(bookId: String, limit: Int): Result<List<String>?> = runCatching {
        val response = api.getBookRecommendations(bookId, limit.coerceIn(1, 25))
        if (response.code() == 404) return@runCatching null
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

    private suspend fun <T> optional(request: suspend () -> Response<T>): T? = try {
        val response = request()
        if (response.isSuccessful) response.body() else null
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    private suspend fun <T> optionalList(request: suspend () -> Response<List<T>>): List<T> =
        optional(request).orEmpty()

    private companion object {
        const val NOTEBOOK_BOOKS = 6
        const val NOTEBOOK_ENTRIES = 10
    }
}
