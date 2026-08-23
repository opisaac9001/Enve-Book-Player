package com.enve.bookorbit.api

import com.enve.bookorbit.dto.BookOrbitAchievementCatalogueDto
import com.enve.bookorbit.dto.BookOrbitAnnotationBookFacetDto
import com.enve.bookorbit.dto.BookOrbitAnnotationBulkRequest
import com.enve.bookorbit.dto.BookOrbitAnnotationBulkResultDto
import com.enve.bookorbit.dto.BookOrbitAnnotationHubItemDto
import com.enve.bookorbit.dto.BookOrbitAnnotationHubPageDto
import com.enve.bookorbit.dto.BookOrbitAudioProgressDto
import com.enve.bookorbit.dto.BookOrbitAnnotationDto
import com.enve.bookorbit.dto.BookOrbitCompletionLatencyDto
import com.enve.bookorbit.dto.BookOrbitCompletionTimelinePointDto
import com.enve.bookorbit.dto.BookOrbitCreateAnnotationRequest
import com.enve.bookorbit.dto.BookOrbitAudioProgressRequest
import com.enve.bookorbit.dto.BookOrbitBookDetailDto
import com.enve.bookorbit.dto.BookOrbitBookmarkDto
import com.enve.bookorbit.dto.BookOrbitBookmarkRequest
import com.enve.bookorbit.dto.BookOrbitBooksPageDto
import com.enve.bookorbit.dto.BookOrbitBooksPageRequest
import com.enve.bookorbit.dto.BookOrbitCollectionBooksRequest
import com.enve.bookorbit.dto.BookOrbitCollectionDto
import com.enve.bookorbit.dto.BookOrbitCollectionOrderRequest
import com.enve.bookorbit.dto.BookOrbitCollectionRequest
import com.enve.bookorbit.dto.BookOrbitCurrentlyReadingWidgetDto
import com.enve.bookorbit.dto.BookOrbitDailyReadingDto
import com.enve.bookorbit.dto.BookOrbitDiversityScoreWidgetDto
import com.enve.bookorbit.dto.BookOrbitEbookProgressRequest
import com.enve.bookorbit.dto.BookOrbitFavoriteDayDto
import com.enve.bookorbit.dto.BookOrbitFileProgressDto
import com.enve.bookorbit.dto.BookOrbitGenreReadingTimeDto
import com.enve.bookorbit.dto.BookOrbitHighlightOfTheDayWidgetDto
import com.enve.bookorbit.dto.BookOrbitLibraryDto
import com.enve.bookorbit.dto.BookOrbitLibraryOverviewWidgetDto
import com.enve.bookorbit.dto.BookOrbitLoginRequest
import com.enve.bookorbit.dto.BookOrbitLoginResponse
import com.enve.bookorbit.dto.BookOrbitMonthlyChallengeWidgetDto
import com.enve.bookorbit.dto.BookOrbitPeakHourDto
import com.enve.bookorbit.dto.BookOrbitProgressFunnelComparisonDto
import com.enve.bookorbit.dto.BookOrbitReadingDnaWidgetDto
import com.enve.bookorbit.dto.BookOrbitReadingGoalWidgetDto
import com.enve.bookorbit.dto.BookOrbitReadingRhythmWidgetDto
import com.enve.bookorbit.dto.BookOrbitReadingSessionRequest
import com.enve.bookorbit.dto.BookOrbitReadingSessionsPageDto
import com.enve.bookorbit.dto.BookOrbitReadingStreakWidgetDto
import com.enve.bookorbit.dto.BookOrbitRecommendationDto
import com.enve.bookorbit.dto.BookOrbitRatingRequest
import com.enve.bookorbit.dto.BookOrbitSourceDistributionDto
import com.enve.bookorbit.dto.BookOrbitStatisticsSummaryDto
import com.enve.bookorbit.dto.BookOrbitStatusRequest
import com.enve.bookorbit.dto.BookOrbitUpdateAnnotationRequest
import com.enve.bookorbit.dto.BookOrbitUserDto
import com.enve.bookorbit.dto.BookOrbitYearProjectionWidgetDto
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.Header
import retrofit2.http.HTTP
import retrofit2.http.PATCH
import retrofit2.http.POST
import retrofit2.http.Path
import retrofit2.http.Query

interface BookOrbitApi {
    @POST("api/v1/auth/login")
    suspend fun login(@Body request: BookOrbitLoginRequest): Response<BookOrbitLoginResponse>

    @POST("api/v1/auth/refresh")
    suspend fun refresh(@Header("Cookie") refreshCookie: String): Response<BookOrbitLoginResponse>

    @GET("api/v1/auth/me")
    suspend fun me(): Response<BookOrbitUserDto>

    @GET("api/v1/collections")
    suspend fun collections(@Query("bookIds") bookIds: String? = null): Response<List<BookOrbitCollectionDto>>

    @GET("api/v1/collections/{collectionId}/books")
    suspend fun collectionBooks(
        @Path("collectionId") collectionId: Int,
        @Query("page") page: Int,
        @Query("size") size: Int,
        @Query("q") query: String? = null,
    ): Response<BookOrbitBooksPageDto>

    @POST("api/v1/collections")
    suspend fun createCollection(@Body request: BookOrbitCollectionRequest): Response<BookOrbitCollectionDto>

    @PATCH("api/v1/collections/{collectionId}")
    suspend fun updateCollection(
        @Path("collectionId") collectionId: Int,
        @Body request: BookOrbitCollectionRequest,
    ): Response<BookOrbitCollectionDto>

    @retrofit2.http.DELETE("api/v1/collections/{collectionId}")
    suspend fun deleteCollection(@Path("collectionId") collectionId: Int): Response<Unit>

    @POST("api/v1/collections/{collectionId}/books")
    suspend fun addCollectionBooks(
        @Path("collectionId") collectionId: Int,
        @Body request: BookOrbitCollectionBooksRequest,
    ): Response<BookOrbitCollectionDto>

    @HTTP(method = "DELETE", path = "api/v1/collections/{collectionId}/books", hasBody = true)
    suspend fun removeCollectionBooks(
        @Path("collectionId") collectionId: Int,
        @Body request: BookOrbitCollectionBooksRequest,
    ): Response<BookOrbitCollectionDto>

    @POST("api/v1/collections/reorder")
    suspend fun reorderCollections(@Body request: BookOrbitCollectionOrderRequest): Response<Unit>

    @GET("api/v1/libraries")
    suspend fun libraries(): Response<List<BookOrbitLibraryDto>>

    @POST("api/v1/libraries/{libraryId}/books")
    suspend fun books(
        @Path("libraryId") libraryId: Int,
        @Body request: BookOrbitBooksPageRequest,
    ): Response<BookOrbitBooksPageDto>

    @GET("api/v1/books/{bookId}")
    suspend fun book(@Path("bookId") bookId: Int): Response<BookOrbitBookDetailDto>

    @PATCH("api/v1/books/{bookId}/metadata")
    suspend fun updateRating(
        @Path("bookId") bookId: Int,
        @Body request: BookOrbitRatingRequest,
    ): Response<BookOrbitBookDetailDto>

    @GET("api/v1/dashboard/widgets/currently-reading")
    suspend fun currentlyReading(): Response<BookOrbitCurrentlyReadingWidgetDto>

    @GET("api/v1/books/{bookId}/audio-progress")
    suspend fun audioProgress(@Path("bookId") bookId: Int): Response<BookOrbitAudioProgressDto>

    @PATCH("api/v1/books/{bookId}/audio-progress")
    suspend fun updateAudioProgress(
        @Path("bookId") bookId: Int,
        @Body request: BookOrbitAudioProgressRequest,
    ): Response<Unit>

    @GET("api/v1/books/files/{fileId}/progress")
    suspend fun ebookProgress(@Path("fileId") fileId: Int): Response<BookOrbitFileProgressDto>

    @POST("api/v1/books/files/{fileId}/progress")
    suspend fun updateEbookProgress(
        @Path("fileId") fileId: Int,
        @Body request: BookOrbitEbookProgressRequest,
    ): Response<Unit>

    @PATCH("api/v1/books/{bookId}/status")
    suspend fun updateStatus(
        @Path("bookId") bookId: Int,
        @Body request: BookOrbitStatusRequest,
    ): Response<Unit>

    @GET("api/v1/books/{bookId}/annotations")
    suspend fun annotations(@Path("bookId") bookId: Int): Response<List<BookOrbitAnnotationDto>>

    @POST("api/v1/books/{bookId}/annotations")
    suspend fun createAnnotation(
        @Path("bookId") bookId: Int,
        @Body request: BookOrbitCreateAnnotationRequest,
    ): Response<BookOrbitAnnotationDto>

    @PATCH("api/v1/books/{bookId}/annotations/{annotationId}")
    suspend fun updateAnnotation(
        @Path("bookId") bookId: Int,
        @Path("annotationId") annotationId: Int,
        @Body request: BookOrbitUpdateAnnotationRequest,
    ): Response<BookOrbitAnnotationDto>

    @retrofit2.http.DELETE("api/v1/books/{bookId}/annotations/{annotationId}")
    suspend fun deleteAnnotation(
        @Path("bookId") bookId: Int,
        @Path("annotationId") annotationId: Int,
    ): Response<Unit>

    @GET("api/v1/books/{bookId}/bookmarks")
    suspend fun bookmarks(@Path("bookId") bookId: Int): Response<List<BookOrbitBookmarkDto>>

    @POST("api/v1/books/{bookId}/bookmarks")
    suspend fun createBookmark(
        @Path("bookId") bookId: Int,
        @Body request: BookOrbitBookmarkRequest,
    ): Response<BookOrbitBookmarkDto>

    @retrofit2.http.DELETE("api/v1/books/{bookId}/bookmarks/{bookmarkId}")
    suspend fun deleteBookmark(
        @Path("bookId") bookId: Int,
        @Path("bookmarkId") bookmarkId: Int,
    ): Response<Unit>

    @GET("api/v1/books/{bookId}/sessions")
    suspend fun readingSessions(
        @Path("bookId") bookId: Int,
        @Query("page") page: Int,
        @Query("pageSize") pageSize: Int,
        @Query("sortBy") sortBy: String = "startedAt",
        @Query("sortDir") sortDir: String = "desc",
    ): Response<BookOrbitReadingSessionsPageDto>

    @POST("api/v1/books/files/{fileId}/sessions")
    suspend fun saveReadingSession(
        @Path("fileId") fileId: Int,
        @Body request: BookOrbitReadingSessionRequest,
    ): Response<Unit>

    @GET("api/v1/user-statistics/summary")
    suspend fun statisticsSummary(): Response<BookOrbitStatisticsSummaryDto>

    @GET("api/v1/user-statistics/daily-reading")
    suspend fun dailyReading(@Query("days") days: Int): Response<List<BookOrbitDailyReadingDto>>

    @GET("api/v1/user-statistics/reading-heatmap")
    suspend fun readingHeatmap(@Query("days") days: Int): Response<List<BookOrbitDailyReadingDto>>

    @GET("api/v1/user-statistics/reading-source-distribution")
    suspend fun readingSourceDistribution(@Query("days") days: Int): Response<BookOrbitSourceDistributionDto>

    @GET("api/v1/user-statistics/peak-hours")
    suspend fun peakHours(@Query("days") days: Int): Response<List<BookOrbitPeakHourDto>>

    @GET("api/v1/user-statistics/favorite-days")
    suspend fun favoriteDays(@Query("days") days: Int): Response<List<BookOrbitFavoriteDayDto>>

    @GET("api/v1/user-statistics/completion-timeline")
    suspend fun completionTimeline(@Query("days") days: Int): Response<List<BookOrbitCompletionTimelinePointDto>>

    @GET("api/v1/user-statistics/progress-funnel")
    suspend fun progressFunnel(
        @Query("days") days: Int,
        @Query("comparePrevious") comparePrevious: Boolean,
    ): Response<BookOrbitProgressFunnelComparisonDto>

    @GET("api/v1/user-statistics/completion-latency")
    suspend fun completionLatency(@Query("days") days: Int): Response<BookOrbitCompletionLatencyDto>

    @GET("api/v1/user-statistics/genre-reading-time")
    suspend fun genreReadingTime(@Query("days") days: Int): Response<List<BookOrbitGenreReadingTimeDto>>

    @GET("api/v1/dashboard/widgets/reading-goal")
    suspend fun readingGoalWidget(): Response<BookOrbitReadingGoalWidgetDto>

    @GET("api/v1/dashboard/widgets/reading-streak")
    suspend fun readingStreakWidget(): Response<BookOrbitReadingStreakWidgetDto>

    @GET("api/v1/dashboard/widgets/library-overview")
    suspend fun libraryOverviewWidget(): Response<BookOrbitLibraryOverviewWidgetDto>

    @GET("api/v1/dashboard/widgets/year-projection")
    suspend fun yearProjectionWidget(): Response<BookOrbitYearProjectionWidgetDto>

    @GET("api/v1/dashboard/widgets/reading-rhythm")
    suspend fun readingRhythmWidget(): Response<BookOrbitReadingRhythmWidgetDto>

    @GET("api/v1/dashboard/widgets/monthly-challenge")
    suspend fun monthlyChallengeWidget(): Response<BookOrbitMonthlyChallengeWidgetDto>

    @GET("api/v1/dashboard/widgets/diversity-score")
    suspend fun diversityScoreWidget(): Response<BookOrbitDiversityScoreWidgetDto>

    @GET("api/v1/dashboard/widgets/reading-dna")
    suspend fun readingDnaWidget(): Response<BookOrbitReadingDnaWidgetDto>

    @GET("api/v1/dashboard/widgets/highlight-of-the-day")
    suspend fun highlightOfTheDayWidget(): Response<BookOrbitHighlightOfTheDayWidgetDto>

    @GET("api/v1/achievements")
    suspend fun achievements(): Response<BookOrbitAchievementCatalogueDto>

    @GET("api/v1/books/{bookId}/recommendations")
    suspend fun recommendations(@Path("bookId") bookId: Int): Response<List<BookOrbitRecommendationDto>>

    @GET("api/v1/books/{bookId}/series-books")
    suspend fun seriesBooks(@Path("bookId") bookId: Int): Response<List<BookOrbitRecommendationDto>>

    @GET("api/v1/books/{bookId}/author-books")
    suspend fun authorBooks(@Path("bookId") bookId: Int): Response<List<BookOrbitRecommendationDto>>

    @GET("api/v1/annotations")
    suspend fun annotationHub(
        @Query("page") page: Int,
        @Query("pageSize") pageSize: Int,
        @Query("status") status: String,
        @Query("search") search: String? = null,
        @Query("bookId") bookId: Int? = null,
        @Query("colors") colors: String? = null,
        @Query("styles") styles: String? = null,
        @Query("origins") origins: String? = null,
        @Query("hasNote") hasNote: Boolean? = null,
        @Query("sortBy") sortBy: String = "createdAt",
        @Query("sortDir") sortDir: String = "desc",
    ): Response<BookOrbitAnnotationHubPageDto>

    @GET("api/v1/annotations/books")
    suspend fun annotationHubBooks(
        @Query("status") status: String,
        @Query("q") query: String? = null,
        @Query("limit") limit: Int? = null,
    ): Response<List<BookOrbitAnnotationBookFacetDto>>

    @POST("api/v1/annotations/bulk")
    suspend fun annotationHubBulk(
        @Body request: BookOrbitAnnotationBulkRequest,
    ): Response<BookOrbitAnnotationBulkResultDto>

    @POST("api/v1/annotations/{annotationId}/restore")
    suspend fun restoreHubAnnotation(
        @Path("annotationId") annotationId: Int,
    ): Response<BookOrbitAnnotationHubItemDto>

    @retrofit2.http.DELETE("api/v1/annotations/{annotationId}")
    suspend fun purgeHubAnnotation(@Path("annotationId") annotationId: Int): Response<Unit>

    @GET("api/v1/annotations/export")
    suspend fun exportAnnotations(
        @Query("format") format: String,
        @Query("status") status: String,
        @Query("search") search: String? = null,
        @Query("bookId") bookId: Int? = null,
        @Query("colors") colors: String? = null,
        @Query("styles") styles: String? = null,
        @Query("origins") origins: String? = null,
        @Query("hasNote") hasNote: Boolean? = null,
    ): Response<okhttp3.ResponseBody>
}
