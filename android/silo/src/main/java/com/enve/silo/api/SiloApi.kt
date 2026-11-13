package com.enve.silo.api

import com.enve.silo.dto.SiloAdminServerStatusDto
import com.enve.silo.dto.SiloAdminStatsDto
import com.enve.silo.dto.SiloAdminUserDto
import com.enve.silo.dto.SiloCatalogItemDto
import com.enve.silo.dto.SiloCollection
import com.enve.silo.dto.SiloEbookProgressEnvelope
import com.enve.silo.dto.SiloEbookProgressRequest
import com.enve.silo.dto.SiloHistoryCardDto
import com.enve.silo.dto.SiloItemDetailDto
import com.enve.silo.dto.SiloLibraryDto
import com.enve.silo.dto.SiloLoginRequest
import com.enve.silo.dto.SiloLoginResponse
import com.enve.silo.dto.SiloPlaybackCapabilitiesDto
import com.enve.silo.dto.SiloPlaybackMutationDto
import com.enve.silo.dto.SiloPlaybackProgressRequest
import com.enve.silo.dto.SiloPlaybackStartRequest
import com.enve.silo.dto.SiloPlaybackStartResponse
import com.enve.silo.dto.SiloPlaybackStopRequest
import com.enve.silo.dto.SiloProfileDto
import com.enve.silo.dto.SiloProgressEntryDto
import com.enve.silo.dto.SiloProgressSyncRequest
import com.enve.silo.dto.SiloProgressSyncResponse
import com.enve.silo.dto.SiloReaderAnnotationCreateRequest
import com.enve.silo.dto.SiloReaderAnnotationPatchRequest
import com.enve.silo.dto.SiloReaderAnnotationRecord
import com.enve.silo.dto.SiloRefreshRequest
import com.enve.silo.dto.SiloRefreshResponse
import com.enve.silo.dto.SiloUserDto
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.HTTP
import retrofit2.http.Header
import retrofit2.http.PATCH
import retrofit2.http.POST
import retrofit2.http.PUT
import retrofit2.http.Path
import retrofit2.http.Query

interface SiloApi {
    @POST("api/v2/auth/login")
    suspend fun login(@Body request: SiloLoginRequest): Response<SiloLoginResponse>

    @POST("api/v2/auth/refresh")
    suspend fun refresh(@Body request: SiloRefreshRequest): Response<SiloRefreshResponse>

    @GET("api/v2/profiles")
    suspend fun profiles(): Response<SiloCollection<SiloProfileDto>>

    @GET("api/v2/account/me")
    suspend fun me(): Response<SiloUserDto>

    @GET("api/v2/admin/stats")
    suspend fun adminStats(@Header("X-Profile-Id") profileId: String): Response<SiloAdminStatsDto>

    @GET("api/v2/admin/server/status")
    suspend fun adminServerStatus(@Header("X-Profile-Id") profileId: String): Response<SiloAdminServerStatusDto>

    @GET("api/v2/admin/users")
    suspend fun adminUsers(
        @Header("X-Profile-Id") profileId: String,
        @Query("cursor") cursor: String?,
        @Query("limit") limit: Int = 200,
    ): Response<SiloCollection<SiloAdminUserDto>>

    @GET("api/v2/user/libraries")
    suspend fun libraries(@Header("X-Profile-Id") profileId: String): Response<SiloCollection<SiloLibraryDto>>

    @GET("api/v2/catalog")
    suspend fun catalog(
        @Header("X-Profile-Id") profileId: String,
        @Query("library_id") libraryId: String,
        @Query("sort") sort: String?,
        @Query("cursor") cursor: String?,
        @Query("limit") limit: Int,
        @Query("skip_total") skipTotal: Boolean = true,
    ): Response<SiloCollection<SiloCatalogItemDto>>

    @GET("api/v2/catalog/items/{id}")
    suspend fun itemDetail(
        @Header("X-Profile-Id") profileId: String,
        @Path("id") id: String,
    ): Response<SiloItemDetailDto>

    @GET("api/v2/history")
    suspend fun history(
        @Header("X-Profile-Id") profileId: String,
        @Query("cursor") cursor: String?,
        @Query("limit") limit: Int,
    ): Response<SiloCollection<SiloHistoryCardDto>>

    @GET("api/v2/recommendations/similar/{item_id}")
    suspend fun similarItems(
        @Header("X-Profile-Id") profileId: String,
        @Path("item_id") itemId: String,
        @Query("limit") limit: Int,
    ): Response<SiloCollection<SiloCatalogItemDto>>

    @GET("api/v2/progress")
    suspend fun progressList(
        @Header("X-Profile-Id") profileId: String,
        @Query("library_id") libraryId: String,
        @Query("cursor") cursor: String?,
        @Query("status") status: String = "in_progress",
        @Query("limit") limit: Int = 200,
    ): Response<SiloCollection<SiloProgressEntryDto>>

    @POST("api/v2/sync/progress")
    suspend fun syncProgress(
        @Header("X-Profile-Id") profileId: String,
        @Body request: SiloProgressSyncRequest,
    ): Response<SiloProgressSyncResponse>

    @GET("api/v2/playback/capabilities")
    suspend fun playbackCapabilities(@Header("X-Profile-Id") profileId: String): Response<SiloPlaybackCapabilitiesDto>

    @POST("api/v2/playback/start")
    suspend fun startPlayback(
        @Header("X-Profile-Id") profileId: String,
        @Body request: SiloPlaybackStartRequest,
    ): Response<SiloPlaybackStartResponse>

    @POST("api/v2/playback/{session_id}/progress")
    suspend fun updatePlaybackProgress(
        @Header("X-Profile-Id") profileId: String,
        @Path("session_id") sessionId: String,
        @Body request: SiloPlaybackProgressRequest,
    ): Response<SiloPlaybackMutationDto>

    @HTTP(method = "DELETE", path = "api/v2/playback/{session_id}", hasBody = true)
    suspend fun stopPlayback(
        @Header("X-Profile-Id") profileId: String,
        @Path("session_id") sessionId: String,
        @Body request: SiloPlaybackStopRequest,
    ): Response<SiloPlaybackMutationDto>

    @PUT("api/v2/ebooks/{content_id}/progress")
    suspend fun updateEbookProgress(
        @Header("X-Profile-Id") profileId: String,
        @Path("content_id") bookId: String,
        @Body request: SiloEbookProgressRequest,
    ): Response<SiloEbookProgressEnvelope>

    @GET("api/v2/ebooks/{content_id}/progress")
    suspend fun ebookProgress(
        @Header("X-Profile-Id") profileId: String,
        @Path("content_id") bookId: String,
    ): Response<SiloEbookProgressEnvelope>

    @GET("api/v2/ebooks/{content_id}/annotations")
    suspend fun annotations(
        @Header("X-Profile-Id") profileId: String,
        @Path("content_id") bookId: String,
        @Query("cursor") cursor: String?,
        @Query("limit") limit: Int = 50,
    ): Response<SiloCollection<SiloReaderAnnotationRecord>>

    @POST("api/v2/ebooks/{content_id}/annotations")
    suspend fun createAnnotation(
        @Header("X-Profile-Id") profileId: String,
        @Path("content_id") bookId: String,
        @Body request: SiloReaderAnnotationCreateRequest,
    ): Response<SiloReaderAnnotationRecord>

    @PATCH("api/v2/ebooks/{content_id}/annotations/{annotation_id}")
    suspend fun updateAnnotation(
        @Header("X-Profile-Id") profileId: String,
        @Header("If-Match") ifMatch: String,
        @Path("content_id") bookId: String,
        @Path("annotation_id") id: String,
        @Body request: SiloReaderAnnotationPatchRequest,
    ): Response<SiloReaderAnnotationRecord>

    @DELETE("api/v2/ebooks/{content_id}/annotations/{annotation_id}")
    suspend fun deleteAnnotation(
        @Header("X-Profile-Id") profileId: String,
        @Header("If-Match") ifMatch: String,
        @Path("content_id") bookId: String,
        @Path("annotation_id") id: String,
    ): Response<Unit>
}
