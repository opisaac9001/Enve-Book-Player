package com.enve.bookorbit

import com.enve.bookorbit.api.BookOrbitApi
import com.enve.bookorbit.dto.BookOrbitAchievementCatalogueDto
import com.enve.bookorbit.dto.BookOrbitCompletionLatencyDto
import com.enve.bookorbit.dto.BookOrbitCompletionTimelinePointDto
import com.enve.bookorbit.dto.BookOrbitDailyReadingDto
import com.enve.bookorbit.dto.BookOrbitDiversityScoreWidgetDto
import com.enve.bookorbit.dto.BookOrbitFavoriteDayDto
import com.enve.bookorbit.dto.BookOrbitGenreReadingTimeDto
import com.enve.bookorbit.dto.BookOrbitHighlightOfTheDayWidgetDto
import com.enve.bookorbit.dto.BookOrbitLibraryOverviewWidgetDto
import com.enve.bookorbit.dto.BookOrbitMonthlyChallengeWidgetDto
import com.enve.bookorbit.dto.BookOrbitPeakHourDto
import com.enve.bookorbit.dto.BookOrbitProgressFunnelComparisonDto
import com.enve.bookorbit.dto.BookOrbitReadingDnaWidgetDto
import com.enve.bookorbit.dto.BookOrbitReadingGoalWidgetDto
import com.enve.bookorbit.dto.BookOrbitReadingRhythmWidgetDto
import com.enve.bookorbit.dto.BookOrbitReadingStreakWidgetDto
import com.enve.bookorbit.dto.BookOrbitSourceDistributionDto
import com.enve.bookorbit.dto.BookOrbitStatisticsSummaryDto
import com.enve.bookorbit.dto.BookOrbitYearProjectionWidgetDto
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton
import retrofit2.Response

data class BookOrbitDashboard(
    val summary: BookOrbitStatisticsSummaryDto?,
    val streak: BookOrbitReadingStreakWidgetDto?,
    val goal: BookOrbitReadingGoalWidgetDto?,
    val libraryOverview: BookOrbitLibraryOverviewWidgetDto?,
    val yearProjection: BookOrbitYearProjectionWidgetDto?,
    val rhythm: BookOrbitReadingRhythmWidgetDto?,
    val monthlyChallenge: BookOrbitMonthlyChallengeWidgetDto?,
    val diversity: BookOrbitDiversityScoreWidgetDto?,
    val readingDna: BookOrbitReadingDnaWidgetDto?,
    val highlightOfTheDay: BookOrbitHighlightOfTheDayWidgetDto?,
    val dailyReading: List<BookOrbitDailyReadingDto>,
    val heatmap: List<BookOrbitDailyReadingDto>,
    val sourceDistribution: BookOrbitSourceDistributionDto?,
    val peakHours: List<BookOrbitPeakHourDto>,
    val favoriteDays: List<BookOrbitFavoriteDayDto>,
    val genreReadingTime: List<BookOrbitGenreReadingTimeDto>,
    val completionTimeline: List<BookOrbitCompletionTimelinePointDto>,
    val progressFunnel: BookOrbitProgressFunnelComparisonDto?,
    val completionLatency: BookOrbitCompletionLatencyDto?,
) {
    val hasAnyData: Boolean
        get() = summary != null || streak != null || goal != null || libraryOverview != null ||
            yearProjection != null || rhythm != null || monthlyChallenge != null || diversity != null ||
            readingDna != null || highlightOfTheDay != null || sourceDistribution != null ||
            progressFunnel != null || completionLatency != null ||
            dailyReading.isNotEmpty() || heatmap.isNotEmpty() || peakHours.isNotEmpty() ||
            favoriteDays.isNotEmpty() || genreReadingTime.isNotEmpty() || completionTimeline.isNotEmpty()
}

@Singleton
class BookOrbitInsightsRepository @Inject constructor(
    private val api: BookOrbitApi,
) {
    suspend fun getDashboard(days: Int): Result<BookOrbitDashboard> = runCatching {
        val window = days.coerceIn(1, 3650)
        val heatmapWindow = maxOf(window, HEATMAP_DAYS)
        val probe = ReachabilityProbe()
        val dashboard = coroutineScope {
            val summary = async { probe.optional { api.statisticsSummary() } }
            val streak = async { probe.optional { api.readingStreakWidget() } }
            val goal = async { probe.optional { api.readingGoalWidget() } }
            val overview = async { probe.optional { api.libraryOverviewWidget() } }
            val projection = async { probe.optional { api.yearProjectionWidget() } }
            val rhythm = async { probe.optional { api.readingRhythmWidget() } }
            val challenge = async { probe.optional { api.monthlyChallengeWidget() } }
            val diversity = async { probe.optional { api.diversityScoreWidget() } }
            val dna = async { probe.optional { api.readingDnaWidget() } }
            val highlight = async { probe.optional { api.highlightOfTheDayWidget() } }
            val daily = async { probe.optionalList { api.dailyReading(window) } }
            val heatmap = async { probe.optionalList { api.readingHeatmap(heatmapWindow) } }
            val distribution = async { probe.optional { api.readingSourceDistribution(window) } }
            val peaks = async { probe.optionalList { api.peakHours(window) } }
            val favorites = async { probe.optionalList { api.favoriteDays(window) } }
            val genres = async { probe.optionalList { api.genreReadingTime(window) } }
            val completions = async { probe.optionalList { api.completionTimeline(window) } }
            val funnel = async { probe.optional { api.progressFunnel(window, comparePrevious = true) } }
            val latency = async { probe.optional { api.completionLatency(window) } }
            BookOrbitDashboard(
                summary = summary.await(),
                streak = streak.await(),
                goal = goal.await(),
                libraryOverview = overview.await(),
                yearProjection = projection.await(),
                rhythm = rhythm.await(),
                monthlyChallenge = challenge.await(),
                diversity = diversity.await(),
                readingDna = dna.await(),
                highlightOfTheDay = highlight.await(),
                dailyReading = daily.await(),
                heatmap = heatmap.await(),
                sourceDistribution = distribution.await(),
                peakHours = peaks.await(),
                favoriteDays = favorites.await(),
                genreReadingTime = genres.await(),
                completionTimeline = completions.await(),
                progressFunnel = funnel.await(),
                completionLatency = latency.await(),
            )
        }
        check(probe.reachedServer) { "BookOrbit statistics are unreachable" }
        dashboard
    }

    suspend fun getAchievements(): Result<BookOrbitAchievementCatalogueDto?> = runCatching {
        val response = api.achievements()
        if (response.code() == 404) return@runCatching null
        if (!response.isSuccessful) error("BookOrbit achievements failed: HTTP ${response.code()}")
        response.body()
    }

    private class ReachabilityProbe {
        private val answered = AtomicBoolean(false)

        val reachedServer: Boolean get() = answered.get()

        suspend fun <T> optional(request: suspend () -> Response<T>): T? = try {
            val response = request()
            answered.set(true)
            if (response.isSuccessful) response.body() else null
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }

        suspend fun <T> optionalList(request: suspend () -> Response<List<T>>): List<T> =
            optional(request).orEmpty()
    }

    private companion object {
        const val HEATMAP_DAYS = 365
    }
}
