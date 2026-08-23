package com.enve.app.data.remote

import com.enve.app.data.remote.dto.*
import com.enve.core.data.remote.dto.AuthResponse
import com.enve.core.data.remote.dto.LoginRequest
import com.enve.core.data.remote.dto.RefreshRequest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import okhttp3.RequestBody
import okhttp3.ResponseBody
import retrofit2.Response
import retrofit2.http.*

@Suppress("unused")
interface GrimmoryApi {

    @GET
    suspend fun fetchRawUrl(
        @Url url: String,
    ): Response<ResponseBody>

    @FormUrlEncoded
    @POST
    suspend fun postFormRawUrl(
        @Url url: String,
        @Field("link") link: String,
    ): Response<ResponseBody>

    @HTTP(method = "PROPFIND", hasBody = true)
    suspend fun propfindRawUrl(
        @Url url: String,
        @Header("Depth") depth: String = "1",
        @Body body: RequestBody,
    ): Response<ResponseBody>

    @POST("api/v1/auth/login")
    suspend fun login(@Body request: LoginRequest): Response<AuthResponse>

    @POST
    suspend fun loginAt(
        @Url url: String,
        @Body request: LoginRequest,
    ): Response<AuthResponse>

    @POST("Users/AuthenticateByName")
    suspend fun jellyfinLogin(
        @Header("X-Emby-Authorization") authHeader: String,
        @Body request: JellyfinAuthRequest,
    ): Response<JellyfinAuthResponse>

    @POST("api/v1/auth/refresh")
    suspend fun refreshToken(@Body request: RefreshRequest): Response<AuthResponse>

    @GET("api/v1/users/me")
    suspend fun getCurrentUser(): Response<UserResponse>

    @GET("api/v1/public-settings")
    suspend fun getPublicSettings(): Response<PublicSettingsDto>

    @GET("api/v1/auth/oidc/state")
    suspend fun getOidcState(): Response<OidcStateDto>

    @POST("api/v1/auth/oidc/callback")
    suspend fun oidcCallback(@Body request: OidcCallbackRequest): Response<AuthResponse>

    @POST("Users/AuthenticateByName")
    suspend fun embyLogin(
        @Header("X-Emby-Authorization") authHeader: String,
        @Body request: JellyfinAuthRequest,
    ): Response<JellyfinAuthResponse>

    @POST("api/Account/login")
    suspend fun kavitaLogin(@Body request: LoginRequest): Response<JsonObject>

    @GET("api/Library/libraries")
    suspend fun kavitaLibraries(): Response<JsonObject>

    @GET("api/Book/library/{libraryId}")
    suspend fun kavitaLibraryBooks(
        @Path("libraryId") libraryId: String,
        @Query("pageNumber") pageNumber: Int = 1,
        @Query("pageSize") pageSize: Int = 100,
    ): Response<JsonObject>

    @GET("api/Account")
    suspend fun kavitaAccount(): Response<KavitaAccountDto>

    @GET("api/Stats/user-stats")
    suspend fun kavitaUserStatBar(@Query("userId") userId: Int): Response<KavitaProfileStatBarDto>

    @GET("api/Stats/user-read")
    suspend fun kavitaUserReadStatistics(@Query("userId") userId: Int): Response<KavitaUserReadStatisticsDto>

    @GET("api/Series/series-with-annotations")
    suspend fun kavitaSeriesWithAnnotations(): Response<List<KavitaSeriesDto>>

    @GET("api/Annotation/all-for-series")
    suspend fun kavitaAnnotationsForSeries(@Query("seriesId") seriesId: Int): Response<List<KavitaAnnotationDto>>

    @GET("Users")
    suspend fun embyUsers(): Response<JsonArray>

    @GET("Users/{userId}/Views")
    suspend fun embyViews(
        @Path("userId") userId: String,
    ): Response<JsonObject>

    @GET("Users/{userId}/Items")
    suspend fun embyItems(
        @Path("userId") userId: String,
        @Query("ParentId") parentId: String,
        @Query("IncludeItemTypes") includeItemTypes: String = "Book,MusicAlbum",
        @Query("Fields") fields: String = "ImageTags,ParentId,PrimaryImageItemId,PrimaryImageTag,ParentPrimaryImageItemId,ParentPrimaryImageTag,AlbumId,AlbumPrimaryImageTag",
        @Query("Recursive") recursive: Boolean = true,
        @Query("Limit") limit: Int = 100,
        @Query("StartIndex") startIndex: Int = 0,
    ): Response<JsonObject>

    @GET("api/v1/app/libraries")
    suspend fun getLibraries(): Response<List<LibraryDto>>

    @GET("api/v1/libraries")
    suspend fun getLibrariesLegacy(): Response<List<LibraryDto>>

    @GET("api/v1/libraries/{libraryId}/book")
    suspend fun getBooksLegacy(
        @retrofit2.http.Path("libraryId") libraryId: String,
        @retrofit2.http.Query("page") page: Int = 0,
        @retrofit2.http.Query("size") size: Int = 500,
    ): Response<List<LegacyBookloreBookDto>>

    @GET("Users/Me")
    suspend fun jellyfinMe(): Response<JsonObject>

    @GET("Users/{userId}/Views")
    suspend fun jellyfinViews(
        @Path("userId") userId: String,
    ): Response<JsonObject>

    @GET("Users/{userId}/Items")
    suspend fun jellyfinItems(
        @Path("userId") userId: String,
        @Query("ParentId") parentId: String,
        @Query("IncludeItemTypes") includeItemTypes: String = "AudioBook,Book",
        @Query("Recursive") recursive: Boolean = true,
        @Query("Limit") limit: Int = 100,
        @Query("StartIndex") startIndex: Int = 0,
    ): Response<JsonObject>

    @GET("Users/{userId}/Items/{itemId}")
    suspend fun jellyfinItemDetail(
        @Path("userId") userId: String,
        @Path("itemId") itemId: String,
    ): Response<JsonObject>

    @GET("api/v1/app/books")
    suspend fun getBooks(
        @Query("libraryId") libraryId: String? = null,
        @Query("shelfId") shelfId: String? = null,
        @Query("status") status: String? = null,
        @Query("search") search: String? = null,
        @Query("fileType") fileType: String? = null,
        @Query("minRating") minRating: Int? = null,
        @Query("maxRating") maxRating: Int? = null,
        @Query("authors") authors: String? = null,
        @Query("language") language: String? = null,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 50,
        @Query("sort") sort: String = "addedOn",
        @Query("dir") dir: String = "desc",
    ): Response<PaginatedBooksResponse>

    @GET("api/v1/app/books/{bookId}")
    suspend fun getBookDetail(@Path("bookId") bookId: String): Response<BookDetailDto>

    @GET("api/v1/app/books/continue-listening")
    suspend fun getContinueListening(
        @Query("limit") limit: Int = 10,
    ): Response<List<BookSummaryDto>>

    @GET("api/v1/app/books/continue-reading")
    suspend fun getContinueReading(
        @Query("limit") limit: Int = 10,
    ): Response<List<BookSummaryDto>>

    @GET("api/v1/app/books/recently-added")
    suspend fun getRecentlyAdded(
        @Query("limit") limit: Int = 10,
    ): Response<List<BookSummaryDto>>

    @GET("api/v1/app/books/recently-scanned")
    suspend fun getRecentlyScanned(
        @Query("limit") limit: Int = 10,
    ): Response<List<BookSummaryDto>>

    @GET("api/v1/app/books/random")
    suspend fun getRandomBooks(
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 20,
        @Query("libraryId") libraryId: String? = null,
    ): Response<PaginatedBooksResponse>

    @GET("api/v1/app/books/search")
    suspend fun searchBooks(
        @Query("q") query: String,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 20,
    ): Response<PaginatedBooksResponse>

    @PUT("api/v1/app/books/{bookId}/status")
    suspend fun updateBookStatus(
        @Path("bookId") bookId: String,
        @Body request: UpdateStatusRequest,
    ): Response<Unit>

    @PUT("api/v1/books/personal-rating")
    suspend fun updateBookRating(
        @Body request: UpdateRatingRequest,
    ): Response<Unit>

    @GET("api/v1/audiobooks/{bookId}/info")
    suspend fun getAudiobookInfo(
        @Path("bookId") bookId: String,
    ): Response<AudiobookInfoDto>

    @GET("api/v1/app/shelves")
    suspend fun getShelves(): Response<List<ShelfDto>>

    @GET("api/v1/shelves")
    suspend fun getLegacyShelves(): Response<List<ShelfDto>>

    @GET("api/v1/shelves/{shelfId}/books")
    suspend fun getShelfBooks(
        @Path("shelfId") shelfId: String,
    ): Response<List<LegacyBookloreBookDto>>

    @GET("api/v1/app/shelves/magic")
    suspend fun getMagicShelves(): Response<List<MagicShelfDto>>

    @GET("api/v1/app/shelves/magic/{magicShelfId}/books")
    suspend fun getMagicShelfBooks(
        @Path("magicShelfId") magicShelfId: String,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 20,
    ): Response<PaginatedBooksResponse>

    @GET("api/v1/app/series")
    suspend fun getSeries(
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 50,
        @Query("sort") sort: String = "recentlyAdded",
        @Query("dir") dir: String = "desc",
        @Query("libraryId") libraryId: String? = null,
        @Query("search") search: String? = null,
        @Query("status") status: String? = null,
    ): Response<PaginatedSeriesResponse>

    @GET("api/v1/app/series/{seriesName}/books")
    suspend fun getSeriesBooks(
        @Path("seriesName") seriesName: String,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 20,
        @Query("sort") sort: String = "seriesNumber",
        @Query("dir") dir: String = "asc",
        @Query("libraryId") libraryId: String? = null,
    ): Response<PaginatedBooksResponse>

    @GET("api/v1/app/notebook/books")
    suspend fun getNotebookBooks(
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 20,
        @Query("search") search: String? = null,
    ): Response<PaginatedNotebookBooksResponse>

    @GET("api/v1/app/notebook/books/{bookId}/entries")
    suspend fun getNotebookEntries(
        @Path("bookId") bookId: String,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 20,
        @Query("types") types: String? = null,
        @Query("search") search: String? = null,
        @Query("sort") sort: String = "date_desc",
    ): Response<PaginatedNotebookEntriesResponse>

    @GET("api/v1/app/filter-options")
    suspend fun getFilters(
        @Query("libraryId") libraryId: String? = null,
        @Query("shelfId") shelfId: String? = null,
        @Query("magicShelfId") magicShelfId: String? = null,
    ): Response<FilterOptionsDto>

    @GET("api/v1/books/{bookId}/recommendations")
    suspend fun getBookRecommendations(
        @Path("bookId") bookId: String,
        @Query("limit") limit: Int = 12,
    ): Response<List<GrimmoryRecommendationDto>>

    @GET("api/v1/user-stats/reading/streak")
    suspend fun getReadingStreak(): Response<ReadingStreakDto>

    @GET("api/v1/user-stats/listening/completion")
    suspend fun getListeningCompletion(): Response<ListeningCompletionDto>

    @GET("api/v1/user-stats/reading/heatmap")
    suspend fun getReadingHeatmap(@Query("year") year: Int): Response<List<GrimmoryActivityDayDto>>

    @GET("api/v1/user-stats/reading/peak-hours")
    suspend fun getReadingPeakHours(@Query("year") year: Int): Response<List<GrimmoryPeakHourDto>>

    @GET("api/v1/user-stats/reading/favorite-days")
    suspend fun getReadingFavoriteDays(@Query("year") year: Int): Response<List<GrimmoryFavoriteDayDto>>

    @GET("api/v1/user-stats/reading/genres")
    suspend fun getReadingGenres(): Response<List<GrimmoryGenreStatDto>>

    @GET("api/v1/user-stats/reading/completion-timeline")
    suspend fun getCompletionTimeline(@Query("year") year: Int): Response<List<GrimmoryCompletionMonthDto>>

    @GET("api/v1/user-stats/reading/book-completion-heatmap")
    suspend fun getCompletionHeatmap(): Response<List<GrimmoryCompletionHeatmapMonthDto>>

    @GET("api/v1/user-stats/reading/page-turner-scores")
    suspend fun getPageTurners(): Response<List<GrimmoryPageTurnerDto>>

    @GET("api/v1/user-stats/reading/book-distributions")
    suspend fun getBookDistributions(): Response<GrimmoryBookDistributionsDto>

    @GET("api/v1/user-stats/reading/speed")
    suspend fun getReadingSpeed(@Query("year") year: Int): Response<List<GrimmoryReadingSpeedDayDto>>

    @GET("api/v1/user-stats/reading/session-scatter")
    suspend fun getReadingSessionScatter(@Query("year") year: Int): Response<List<GrimmorySessionPointDto>>

    @GET("api/v1/user-stats/reading/book-timeline")
    suspend fun getBookTimeline(@Query("year") year: Int): Response<List<GrimmoryBookTimelineEntryDto>>

    @GET("api/v1/user-stats/reading/completion-race")
    suspend fun getCompletionRace(@Query("year") year: Int): Response<List<GrimmoryCompletionRacePointDto>>

    @GET("api/v1/user-stats/listening/weekly-trend")
    suspend fun getListeningTrend(@Query("weeks") weeks: Int = 26): Response<List<GrimmoryListeningWeekDto>>

    @GET("api/v1/user-stats/listening/monthly-pace")
    suspend fun getListeningPace(@Query("months") months: Int = 12): Response<List<GrimmoryListeningMonthDto>>

    @GET("api/v1/user-stats/listening/finish-funnel")
    suspend fun getListeningFunnel(): Response<GrimmoryListeningFunnelDto>

    @GET("api/v1/user-stats/listening/peak-hours")
    suspend fun getListeningPeakHours(@Query("year") year: Int): Response<List<GrimmoryPeakHourDto>>

    @GET("api/v1/user-stats/listening/favorite-days")
    suspend fun getListeningFavoriteDays(@Query("year") year: Int): Response<List<GrimmoryFavoriteDayDto>>

    @GET("api/v1/user-stats/listening/genres")
    suspend fun getListeningGenres(): Response<List<GrimmoryGenreStatDto>>

    @GET("api/v1/user-stats/listening/authors")
    suspend fun getListeningAuthors(): Response<List<GrimmoryAuthorStatDto>>

    @GET("api/v1/user-stats/listening/session-scatter")
    suspend fun getListeningSessionScatter(): Response<List<GrimmorySessionPointDto>>

    @GET("api/v1/user-stats/listening/longest-books")
    suspend fun getLongestAudiobooks(): Response<List<GrimmoryLongestAudiobookDto>>

    @POST("api/v1/reading-sessions")
    suspend fun createReadingSession(
        @Body request: ReadingSessionRequest,
    ): Response<Unit>

    @GET("api/v1/reading-sessions/book/{bookId}")
    suspend fun getReadingSessionsForBook(
        @Path("bookId") bookId: String,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 5,
    ): Response<PaginatedReadingSessionsResponse>

    @GET("api/v1/bookmarks/book/{bookId}")
    suspend fun getBookmarksForBook(
        @Path("bookId") bookId: String,
    ): Response<List<GrimmoryBookmarkDto>>

    @POST("api/v1/bookmarks")
    suspend fun createBookmark(
        @Body request: GrimmoryBookmarkCreateRequest,
    ): Response<GrimmoryBookmarkDto>

    @PUT("api/v1/bookmarks/{bookmarkId}")
    suspend fun updateBookmark(
        @Path("bookmarkId") bookmarkId: Long,
        @Body request: GrimmoryBookmarkUpdateRequest,
    ): Response<GrimmoryBookmarkDto>

    @DELETE("api/v1/bookmarks/{bookmarkId}")
    suspend fun deleteBookmark(
        @Path("bookmarkId") bookmarkId: Long,
    ): Response<Unit>

    @GET("api/v1/app/authors")
    suspend fun getAuthors(
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 30,
        @Query("sort") sort: String = "name",
        @Query("dir") dir: String = "asc",
        @Query("libraryId") libraryId: String? = null,
        @Query("search") search: String? = null,
        @Query("hasPhoto") hasPhoto: Boolean? = null,
    ): Response<PaginatedAuthorsResponse>

    @GET("api/v1/app/authors/{authorId}")
    suspend fun getAuthorDetail(
        @Path("authorId") authorId: String,
    ): Response<AuthorDetailDto>

    @GET("api/v1/app/books/{bookId}/progress")
    suspend fun getAppBookProgress(
        @Path("bookId") bookId: String,
    ): Response<GrimmoryAppBookProgressDto>

    @PUT("api/v1/app/books/{bookId}/progress")
    suspend fun putAppBookProgress(
        @Path("bookId") bookId: String,
        @Body request: GrimmoryUpdateProgressRequest,
    ): Response<Unit>

    @POST("api/v1/books/progress")
    suspend fun postBookProgress(
        @Body request: GrimmoryProgressRequest,
    ): Response<Unit>

    @GET("api/v1/annotations/book/{bookId}")
    suspend fun getAnnotationsForBook(
        @Path("bookId") bookId: String,
    ): Response<List<GrimmoryAnnotationDto>>

    @POST("api/v1/annotations")
    suspend fun createAnnotation(
        @Body request: GrimmoryAnnotationCreateRequest,
    ): Response<GrimmoryAnnotationDto>

    @PUT("api/v1/annotations/{annotationId}")
    suspend fun updateAnnotation(
        @Path("annotationId") annotationId: Long,
        @Body request: GrimmoryAnnotationUpdateRequest,
    ): Response<GrimmoryAnnotationDto>

    @DELETE("api/v1/annotations/{serverId}")
    suspend fun deleteAnnotation(
        @Path("serverId") serverId: Long,
    ): Response<Unit>

    @GET("api/v2/book-notes/book/{bookId}")
    suspend fun getBookNotesForBook(
        @Path("bookId") bookId: String,
    ): Response<List<GrimmoryBookNoteDto>>

    @POST("api/v2/book-notes")
    suspend fun createBookNote(
        @Body request: GrimmoryBookNoteCreateRequest,
    ): Response<GrimmoryBookNoteDto>

    @PUT("api/v2/book-notes/{noteId}")
    suspend fun updateBookNote(
        @Path("noteId") noteId: Long,
        @Body request: GrimmoryBookNoteUpdateRequest,
    ): Response<GrimmoryBookNoteDto>

    @DELETE("api/v2/book-notes/{noteId}")
    suspend fun deleteBookNote(
        @Path("noteId") noteId: Long,
    ): Response<Unit>
}
