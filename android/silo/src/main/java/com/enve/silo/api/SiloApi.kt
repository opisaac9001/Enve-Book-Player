package com.enve.silo.api

import com.enve.silo.dto.SiloCatalogResponse
import com.enve.silo.dto.SiloAdminServerStatusDto
import com.enve.silo.dto.SiloAdminStatsDto
import com.enve.silo.dto.SiloAdminUserDto
import com.enve.silo.dto.SiloEbookProgressRequest
import com.enve.silo.dto.SiloEbookProgressResponse
import com.enve.silo.dto.SiloItemDetailDto
import com.enve.silo.dto.SiloItemListResponse
import com.enve.silo.dto.SiloScoredItemsResponse
import com.enve.silo.dto.SiloLoginRequest
import com.enve.silo.dto.SiloLoginResponse
import com.enve.silo.dto.SiloPlaybackProgressRequest
import com.enve.silo.dto.SiloPlaybackStartRequest
import com.enve.silo.dto.SiloPlaybackStartResponse
import com.enve.silo.dto.SiloProfilesResponse
import com.enve.silo.dto.SiloProgressListResponse
import com.enve.silo.dto.SiloProgressSyncRequest
import com.enve.silo.dto.SiloProgressSyncResponse
import com.enve.silo.dto.SiloReaderAnnotationRecord
import com.enve.silo.dto.SiloReaderAnnotationRequest
import com.enve.silo.dto.SiloReaderAnnotationsEnvelope
import com.enve.silo.dto.SiloRefreshRequest
import com.enve.silo.dto.SiloRefreshResponse
import com.enve.silo.dto.SiloUserDto
import kotlinx.serialization.json.JsonElement
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.Header
import retrofit2.http.PATCH
import retrofit2.http.POST
import retrofit2.http.PUT
import retrofit2.http.Path
import retrofit2.http.Query

interface SiloApi {
    @POST("api/v1/auth/login")
    suspend fun login(@Body request: SiloLoginRequest): Response<SiloLoginResponse>

    @POST("api/v1/auth/refresh")
    suspend fun refresh(@Body request: SiloRefreshRequest): Response<SiloRefreshResponse>

    @GET("api/v1/profiles")
    suspend fun profiles(): Response<SiloProfilesResponse>

    @GET("api/v1/auth/me")
    suspend fun me(): Response<SiloUserDto>

    @GET("api/v1/admin/stats")
    suspend fun adminStats(): Response<SiloAdminStatsDto>

    @GET("api/v1/admin/server/status")
    suspend fun adminServerStatus(): Response<SiloAdminServerStatusDto>

    @GET("api/v1/admin/users")
    suspend fun adminUsers(): Response<List<SiloAdminUserDto>>

    @GET("api/v1/user/libraries")
    suspend fun libraries(): Response<JsonElement>

    @GET("api/v1/catalog")
    suspend fun catalog(
        @Header("X-Profile-Id") profileId: String,
        @Query("library_id") libraryId: String,
        @Query("type") type: String = "audiobook,ebook",
        @Query("offset") offset: Int,
        @Query("limit") limit: Int,
        @Query("sort") sort: String = "title",
        @Query("order") order: String = "asc",
        @Query("include_total") includeTotal: Boolean = true,
    ): Response<SiloCatalogResponse>

    @GET("api/v1/catalog/items/{id}")
    suspend fun itemDetail(@Path("id") id: String): Response<SiloItemDetailDto>

    @GET("api/v1/history")
    suspend fun history(
        @Header("X-Profile-Id") profileId: String,
        @Query("limit") limit: Int,
        @Query("offset") offset: Int = 0,
    ): Response<SiloItemListResponse>

    @GET("api/v1/recommendations/similar/{itemId}")
    suspend fun similarItems(
        @Header("X-Profile-Id") profileId: String,
        @Path("itemId") itemId: String,
        @Query("limit") limit: Int,
    ): Response<SiloScoredItemsResponse>

    @GET("api/v1/progress")
    suspend fun progressList(
        @Header("X-Profile-Id") profileId: String,
        @Query("status") status: String = "in_progress",
        @Query("limit") limit: Int = 200,
    ): Response<SiloProgressListResponse>

    @POST("api/v1/playback/start")
    suspend fun startPlayback(
        @Header("X-Profile-Id") profileId: String,
        @Body request: SiloPlaybackStartRequest,
    ): Response<SiloPlaybackStartResponse>

    @POST("api/v1/playback/{sessionId}/progress")
    suspend fun updatePlaybackProgress(
        @Header("X-Profile-Id") profileId: String,
        @Path("sessionId") sessionId: String,
        @Body request: SiloPlaybackProgressRequest,
    ): Response<Unit>

    @DELETE("api/v1/playback/{sessionId}")
    suspend fun stopPlayback(
        @Header("X-Profile-Id") profileId: String,
        @Path("sessionId") sessionId: String,
    ): Response<Unit>

    @POST("api/v1/sync/progress")
    suspend fun syncProgress(
        @Header("X-Profile-Id") profileId: String,
        @Body request: SiloProgressSyncRequest,
    ): Response<SiloProgressSyncResponse>

    @PUT("api/v1/ebooks/{bookId}/progress")
    suspend fun updateEbookProgress(
        @Header("X-Profile-Id") profileId: String,
        @Path("bookId") bookId: String,
        @Body request: SiloEbookProgressRequest,
    ): Response<Unit>

    @GET("api/v1/ebooks/{bookId}/progress")
    suspend fun ebookProgress(
        @Header("X-Profile-Id") profileId: String,
        @Path("bookId") bookId: String,
    ): Response<SiloEbookProgressResponse>

    @GET("api/v1/ebooks/{bookId}/annotations")
    suspend fun annotations(
        @Header("X-Profile-Id") profileId: String,
        @Path("bookId") bookId: String,
    ): Response<SiloReaderAnnotationsEnvelope>

    @POST("api/v1/ebooks/{bookId}/annotations")
    suspend fun createAnnotation(
        @Header("X-Profile-Id") profileId: String,
        @Path("bookId") bookId: String,
        @Body request: SiloReaderAnnotationRequest,
    ): Response<SiloReaderAnnotationRecord>

    @PATCH("api/v1/ebooks/{bookId}/annotations/{id}")
    suspend fun updateAnnotation(
        @Header("X-Profile-Id") profileId: String,
        @Path("bookId") bookId: String,
        @Path("id") id: String,
        @Body request: SiloReaderAnnotationRequest,
    ): Response<SiloReaderAnnotationRecord>

    @DELETE("api/v1/ebooks/{bookId}/annotations/{id}")
    suspend fun deleteAnnotation(
        @Header("X-Profile-Id") profileId: String,
        @Path("bookId") bookId: String,
        @Path("id") id: String,
    ): Response<Unit>
}
