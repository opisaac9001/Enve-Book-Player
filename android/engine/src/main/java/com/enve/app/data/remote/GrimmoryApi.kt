package com.enve.app.data.remote

import com.enve.app.data.remote.dto.*
import com.enve.core.data.remote.dto.AuthResponse
import com.enve.core.data.remote.dto.LoginRequest
import com.enve.core.data.remote.dto.RefreshRequest
import kotlinx.serialization.json.JsonObject
import okhttp3.RequestBody
import okhttp3.ResponseBody
import retrofit2.Response
import retrofit2.http.*

const val GRIMMORY_MAX_PAGE_SIZE = 100

@Suppress("unused")
interface GrimmoryApi {

    @GET
    suspend fun fetchRawUrl(
        @Url url: String,
    ): Response<ResponseBody>

    @GET
    suspend fun torBoxList(
        @Url url: String,
    ): Response<TorBoxListResponseDto>

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

    @POST
    suspend fun jellyfinLogin(
        @Url url: String,
        @Header("Authorization") authHeader: String,
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

    @POST
    suspend fun embyLogin(
        @Url url: String,
        @Header("X-Emby-Authorization") authHeader: String,
        @Body request: JellyfinAuthRequest,
    ): Response<JellyfinAuthResponse>

    @POST
    suspend fun kavitaLogin(@Url url: String, @Body request: LoginRequest): Response<JsonObject>

    @GET("api/Library/libraries")
    suspend fun kavitaLibraries(): Response<List<KavitaLibraryDto>>

    @POST("api/Series/v2")
    suspend fun kavitaSeries(
        @Query("pageNumber") pageNumber: Int,
        @Query("pageSize") pageSize: Int,
        @Body filter: KavitaSeriesFilterDto,
    ): Response<List<KavitaSeriesDto>>

    @GET("api/Series/volumes")
    suspend fun kavitaVolumes(@Query("seriesId") seriesId: Int): Response<List<KavitaVolumeDto>>

    @GET("api/Series/{seriesId}")
    suspend fun kavitaSeriesDetail(@Path("seriesId") seriesId: Int): Response<KavitaSeriesDto>

    @GET("api/Reader/get-progress")
    suspend fun kavitaProgress(@Query("chapterId") chapterId: Int): Response<KavitaProgressDto>

    @POST("api/Reader/progress")
    suspend fun kavitaSaveProgress(@Body progress: KavitaSaveProgressDto): Response<Unit>

    @GET("api/Account")
    suspend fun kavitaAccount(): Response<KavitaAccountDto>

    @GET("api/Stats/user-stats")
    suspend fun kavitaUserStatBar(
        @Query("userId") userId: Int,
        @Query("libraries") libraries: List<Int>,
        @Query("TimeZoneId") timeZoneId: String,
    ): Response<KavitaProfileStatBarDto>

    @GET("api/Stats/user-read")
    suspend fun kavitaUserReadStatistics(@Query("userId") userId: Int): Response<KavitaUserReadStatisticsDto>

    @GET("api/Series/series-with-annotations")
    suspend fun kavitaSeriesWithAnnotations(): Response<List<KavitaSeriesDto>>

    @GET("api/Annotation/all-for-series")
    suspend fun kavitaAnnotationsForSeries(@Query("seriesId") seriesId: Int): Response<List<KavitaAnnotationDto>>

    @GET("Users")
    suspend fun embyUsers(): Response<List<JellyfinUserDto>>

    @GET("Users/{userId}/Views")
    suspend fun embyViews(
        @Path("userId") userId: String,
    ): Response<MediaBrowserItemsDto>

    @GET("Users/{userId}/Items")
    suspend fun embyItems(
        @Path("userId") userId: String,
        @Query("ParentId") parentId: String,
        @Query("IncludeItemTypes") includeItemTypes: String = "Book,MusicAlbum",
        @Query("Fields") fields: String = "ImageTags,ParentId,PrimaryImageItemId,PrimaryImageTag,ParentPrimaryImageItemId,ParentPrimaryImageTag,AlbumId,AlbumPrimaryImageTag,Composers",
        @Query("Recursive") recursive: Boolean = true,
        @Query("Limit") limit: Int = 100,
        @Query("StartIndex") startIndex: Int = 0,
    ): Response<MediaBrowserItemsDto>

    @GET("api/v1/libraries")
    suspend fun getLibraries(): Response<List<LibraryDto>>

    @GET("api/v1/libraries/{libraryId}/book")
    suspend fun getBooksLegacy(
        @retrofit2.http.Path("libraryId") libraryId: String,
        @retrofit2.http.Query("page") page: Int = 0,
        @retrofit2.http.Query("size") size: Int = 500,
    ): Response<List<LegacyBookloreBookDto>>

    @GET("api/v1/books/batch")
    suspend fun getBooksBatch(
        @Query("ids") ids: String,
    ): Response<List<LegacyBookloreBookDto>>

    @POST("Users/{userId}/Items/{itemId}/UserData")
    suspend fun mediaBrowserUpdateUserData(
        @Path("userId") userId: String,
        @Path("itemId") itemId: String,
        @Body body: MediaBrowserUserDataUpdate,
    ): Response<Unit>

    @POST("Sessions/Playing")
    suspend fun mediaBrowserPlaybackStarted(@Body report: MediaBrowserPlaybackReport): Response<Unit>

    @POST("Sessions/Playing/Progress")
    suspend fun mediaBrowserPlaybackProgress(@Body report: MediaBrowserPlaybackReport): Response<Unit>

    @POST("Sessions/Playing/Stopped")
    suspend fun mediaBrowserPlaybackStopped(@Body report: MediaBrowserPlaybackReport): Response<Unit>

    @GET("Users/Me")
    suspend fun jellyfinMe(): Response<JellyfinUserDto>

    @GET("Users/{userId}/Views")
    suspend fun jellyfinViews(
        @Path("userId") userId: String,
    ): Response<MediaBrowserItemsDto>

    @GET("Users/{userId}/Items")
    suspend fun jellyfinItems(
        @Path("userId") userId: String,
        @Query("ParentId") parentId: String,
        @Query("IncludeItemTypes") includeItemTypes: String = "AudioBook,Book",
        @Query("Fields") fields: String = "People",
        @Query("Recursive") recursive: Boolean = true,
        @Query("Limit") limit: Int = 100,
        @Query("StartIndex") startIndex: Int = 0,
    ): Response<MediaBrowserItemsDto>

    @GET("Users/{userId}/Items/{itemId}")
    suspend fun jellyfinItemDetail(
        @Path("userId") userId: String,
        @Path("itemId") itemId: String,
    ): Response<JsonObject>

    @GET("api/v1/books/page")
    suspend fun getBooksPage(
        @Query("facet") facets: List<String> = emptyList(),
        @Query("query") query: String? = null,
        @Query("sort") sort: String,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = GRIMMORY_MAX_PAGE_SIZE,
    ): Response<GrimmoryBrowsePage<LegacyBookloreBookDto>>

    @GET("api/v1/books/ids")
    fun getCatalogBookIds(
        @Query("facet") facets: List<String>,
        @Query("sort") sort: String,
    ): retrofit2.Call<kotlinx.serialization.json.JsonElement>

    @GET("api/v1/books/page")
    fun getCatalogBooks(
        @Query("facet") facets: List<String>,
        @Query("sort") sort: String,
        @Query("page") page: Int,
        @Query("size") size: Int,
    ): retrofit2.Call<kotlinx.serialization.json.JsonElement>

    @GET("api/v1/books/batch")
    fun getCatalogInventory(@Query("ids") ids: String): retrofit2.Call<kotlinx.serialization.json.JsonElement>

    @GET("api/v1/libraries/{libraryId}/book")
    fun getCatalogBooksLegacy(@Path("libraryId") libraryId: String): retrofit2.Call<kotlinx.serialization.json.JsonElement>

    @GET("api/v1/libraries")
    fun getCatalogLibraries(): retrofit2.Call<List<LibraryDto>>

    @GET("api/v1/books/{bookId}")
    suspend fun getBook(
        @Path("bookId") bookId: String,
        @Query("withDescription") withDescription: Boolean = true,
    ): Response<LegacyBookloreBookDto>

    @POST("api/v1/books/status")
    suspend fun updateReadStatus(
        @Body request: ReadStatusUpdateRequest,
    ): Response<Unit>

    @PUT("api/v1/books/personal-rating")
    suspend fun updateBookRating(
        @Body request: UpdateRatingRequest,
    ): Response<Unit>

    @GET("api/v1/audiobooks/{bookId}/info")
    suspend fun getAudiobookInfo(
        @Path("bookId") bookId: String,
    ): Response<AudiobookInfoDto>

    @GET("api/v1/shelves")
    suspend fun getShelves(): Response<List<ShelfDto>>

    @POST("api/v1/shelves")
    suspend fun createShelf(@Body request: GrimmoryCreateShelfRequest): Response<ShelfDto>

    @POST("api/v1/books/shelves")
    suspend fun assignShelf(@Body request: GrimmoryShelfAssignmentRequest): Response<Unit>

    @GET("api/v1/shelves/{shelfId}/books")
    suspend fun getShelfBooks(
        @Path("shelfId") shelfId: String,
    ): Response<List<LegacyBookloreBookDto>>

    @GET("api/magic-shelves")
    suspend fun getMagicShelves(): Response<List<MagicShelfDto>>

    @GET("api/v1/books/facets/series")
    suspend fun getSeriesFacet(
        @Query("page") page: Int = 0,
        @Query("size") size: Int = GRIMMORY_MAX_PAGE_SIZE,
    ): Response<GrimmoryFacetGroupsResponse>

    @GET("api/v1/notebook")
    suspend fun getNotebookEntries(
        @Query("size") size: Int,
        @Query("types") types: List<String> = listOf("NOTE", "HIGHLIGHT", "BOOKMARK"),
        @Query("sort") sort: String = "desc",
    ): Response<GrimmoryBrowsePage<NotebookEntryDto>>

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

    @GET("api/v1/authors/page")
    suspend fun getAuthors(
        @Query("query") query: String? = null,
        @Query("sort") sort: String = "name",
        @Query("page") page: Int = 0,
        @Query("size") size: Int = GRIMMORY_MAX_PAGE_SIZE,
    ): Response<GrimmoryBrowsePage<AuthorSummaryDto>>

    @GET("api/v1/app/books/{bookId}/progress")
    suspend fun getAppBookProgress(
        @Path("bookId") bookId: String,
    ): Response<GrimmoryAppBookProgressDto>

    @GET("api/v1/books/{bookId}")
    suspend fun getBookProgressDetail(
        @Path("bookId") bookId: String,
    ): Response<GrimmoryBookProgressDetailDto>

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
