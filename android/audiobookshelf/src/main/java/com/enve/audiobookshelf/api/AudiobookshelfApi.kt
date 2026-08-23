package com.enve.audiobookshelf.api

import com.enve.audiobookshelf.dto.*
import com.enve.core.data.remote.dto.*
import retrofit2.Response
import retrofit2.http.*

interface AudiobookshelfApi {
    @POST("login")
    @Headers("x-return-tokens: true")
    suspend fun login(@Body request: AbsLoginRequest): Response<AbsLoginResponse>

    @POST
    @Headers("x-return-tokens: true")
    suspend fun loginAt(
        @Url url: String,
        @Body request: AbsLoginRequest,
    ): Response<AbsLoginResponse>

    @POST("auth/refresh")
    @Headers("Accept: application/json", "x-return-tokens: true")
    suspend fun refresh(@Header("x-refresh-token") refreshToken: String): Response<AbsLoginResponse>

    @POST("api/authorize")
    suspend fun authorize(): Response<Unit>

    @GET("api/libraries")
    suspend fun getLibraries(): Response<AbsLibrariesResponse>

    @GET("api/libraries/{libraryId}/items")
    suspend fun getLibraryItems(
        @Path("libraryId") libraryId: String,
        @Query("limit") limit: Int = 500,
        @Query("page") page: Int = 0,
        @Query("minified") minified: Int = 1,
        @Query("sort") sort: String = "media.metadata.title",
        @Query("desc") desc: Int = 0,
    ): Response<AbsLibraryItemsResponse>

    @GET("api/items/{itemId}")
    suspend fun getItemDetail(
        @Path("itemId") itemId: String,
    ): Response<AbsLibraryItemDto>

    @PATCH("api/items/{itemId}/media")
    suspend fun updateMetadata(
        @Path("itemId") itemId: String,
        @Body request: AbsMetadataUpdateRequest,
    ): Response<okhttp3.ResponseBody>

    @GET("api/libraries/{libraryId}/matchall")
    suspend fun matchAllLibraryItems(
        @Path("libraryId") libraryId: String,
    ): Response<Unit>

    @GET("api/items/{itemId}/ebook")
    suspend fun getEbookFile(
        @Path("itemId") itemId: String,
    ): Response<okhttp3.ResponseBody>

    @POST("api/items/{itemId}/play")
    suspend fun startPlaybackSession(
        @Path("itemId") itemId: String,
        @Body request: AbsPlaybackStartRequest = AbsPlaybackStartRequest(),
    ): Response<AbsPlaybackSessionDto>

    @POST("api/session/{sessionId}/sync")
    suspend fun syncPlaybackSession(
        @Path("sessionId") sessionId: String,
        @Body request: AbsPlaybackSessionUpdateRequest,
    ): Response<Unit>

    @POST("api/session/{sessionId}/close")
    suspend fun closePlaybackSession(
        @Path("sessionId") sessionId: String,
        @Body request: AbsPlaybackSessionUpdateRequest,
    ): Response<Unit>

    @PATCH("api/me/progress/{libraryItemId}")
    suspend fun updateProgress(
        @Path("libraryItemId") libraryItemId: String,
        @Body request: AbsProgressUpdateRequest,
    ): Response<Unit>

    @GET("api/me/items-in-progress")
    suspend fun getItemsInProgress(@Query("limit") limit: Int = 40): Response<AbsLibraryItemsResponse>

    @GET("api/me/progress/{libraryItemId}")
    suspend fun getProgress(
        @Path("libraryItemId") libraryItemId: String,
    ): Response<AbsMediaProgressDto>

    @GET("api/libraries/{libraryId}/authors")
    suspend fun getAuthorsInLibrary(
        @Path("libraryId") libraryId: String,
    ): Response<com.enve.audiobookshelf.dto.AbsAuthorsResponse>

    @GET("api/libraries/{libraryId}/series")
    suspend fun getSeriesInLibrary(
        @Path("libraryId") libraryId: String,
    ): Response<com.enve.audiobookshelf.dto.AbsSeriesResponse>

    @GET("api/me")
    suspend fun getMe(): Response<com.enve.audiobookshelf.dto.AbsMeResponse>

    @GET("api/me/listening-stats")
    suspend fun getListeningStats(): Response<com.enve.audiobookshelf.dto.AbsListeningStatsDto>

    @POST("api/me/item/{itemId}/bookmark")
    suspend fun createBookmark(
        @Path("itemId") itemId: String,
        @Body body: com.enve.audiobookshelf.dto.AbsBookmarkRequest,
    ): Response<com.enve.audiobookshelf.dto.AbsBookmarkDto>

    @PATCH("api/me/item/{itemId}/bookmark")
    suspend fun updateBookmark(
        @Path("itemId") itemId: String,
        @Body body: com.enve.audiobookshelf.dto.AbsBookmarkRequest,
    ): Response<com.enve.audiobookshelf.dto.AbsBookmarkDto>

    @DELETE("api/me/item/{itemId}/bookmark/{time}")
    suspend fun deleteBookmark(
        @Path("itemId") itemId: String,
        @Path("time") time: Double,
    ): Response<Unit>
}
