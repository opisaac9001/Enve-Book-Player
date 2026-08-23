package com.enve.storyteller.api

import com.enve.storyteller.dto.StorytellerAlignmentFacetsDto
import com.enve.storyteller.dto.StorytellerAlignmentReportDto
import com.enve.storyteller.dto.StorytellerAppTokenRequest
import com.enve.storyteller.dto.StorytellerAudioManifestDto
import com.enve.storyteller.dto.StorytellerBookDto
import com.enve.storyteller.dto.StorytellerCollectionDto
import com.enve.storyteller.dto.StorytellerPositionRequest
import com.enve.storyteller.dto.StorytellerPositionResponse
import com.enve.storyteller.dto.StorytellerRatingUpdateRequest
import com.enve.storyteller.dto.StorytellerSeriesDto
import com.enve.storyteller.dto.StorytellerStatusDto
import com.enve.storyteller.dto.StorytellerStatusUpdateRequest
import com.enve.storyteller.dto.StorytellerTokenResponse
import com.enve.storyteller.dto.StorytellerUserDto
import okhttp3.ResponseBody
import okhttp3.RequestBody
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.PUT
import retrofit2.http.Path
import retrofit2.http.Query
import retrofit2.http.Url

interface StorytellerApi {

    @POST("api/v2/token")
    suspend fun login(@Body body: RequestBody): Response<StorytellerTokenResponse>

    @POST
    suspend fun loginAt(
        @Url url: String,
        @Body body: RequestBody,
    ): Response<StorytellerTokenResponse>

    @POST("api/v2/token/app")
    suspend fun exchangeAppToken(@Body request: StorytellerAppTokenRequest): Response<StorytellerTokenResponse>

    @POST
    suspend fun exchangeAppTokenAt(
        @Url url: String,
        @Body request: StorytellerAppTokenRequest,
    ): Response<StorytellerTokenResponse>

    @GET("api/v2/user")
    suspend fun getCurrentUser(): Response<StorytellerUserDto>

    @GET("api/v2/books")
    suspend fun getBooks(): Response<ResponseBody>

    @GET("api/v2/books/{bookId}")
    suspend fun getBook(@Path("bookId") bookId: String): Response<StorytellerBookDto>

    @PUT("api/v2/books/{bookId}")
    suspend fun updateBook(
        @Path("bookId") bookId: String,
        @Body body: RequestBody,
    ): Response<StorytellerBookDto>

    @GET("api/v2/collections")
    suspend fun getCollections(): Response<ResponseBody>

    @GET("api/v2/series")
    suspend fun getSeries(): Response<ResponseBody>

    @GET("api/v2/statuses")
    suspend fun getStatuses(): Response<ResponseBody>

    @PUT("api/v2/books/{bookId}/status")
    suspend fun updateStatus(
        @Path("bookId") bookId: String,
        @Body request: StorytellerStatusUpdateRequest,
    ): Response<Unit>

    @PUT("api/v2/books/{bookId}/rating")
    suspend fun updateRating(
        @Path("bookId") bookId: String,
        @Body request: StorytellerRatingUpdateRequest,
    ): Response<Unit>

    @GET("api/v2/books/{bookId}/listen/manifest.json")
    suspend fun getAudioManifest(@Path("bookId") bookId: String): Response<StorytellerAudioManifestDto>

    @GET("api/v2/books/{bookId}/positions")
    suspend fun getPosition(@Path("bookId") bookId: String): Response<StorytellerPositionResponse>

    @POST("api/v2/books/{bookId}/positions")
    suspend fun updatePosition(
        @Path("bookId") bookId: String,
        @Body request: StorytellerPositionRequest,
    ): Response<Unit>

    @GET("api/v2/books/{bookId}/cover")
    suspend fun getCover(
        @Path("bookId") bookId: String,
        @Query("w") width: Int = 400,
        @Query("audio") audio: Boolean? = null,
    ): Response<okhttp3.ResponseBody>

    @GET("api/v2/shelves")
    suspend fun getShelves(): Response<ResponseBody>

    @POST("api/v2/shelves")
    suspend fun createShelf(@Body body: RequestBody): Response<Unit>

    @PUT("api/v2/shelves/{uuid}")
    suspend fun updateShelf(
        @Path("uuid") uuid: String,
        @Body body: RequestBody,
    ): Response<Unit>

    @DELETE("api/v2/shelves/{uuid}")
    suspend fun deleteShelf(@Path("uuid") uuid: String): Response<Unit>

    @GET("api/v2/books/alignment-facets")
    suspend fun getAlignmentFacets(): Response<StorytellerAlignmentFacetsDto>

    @GET("api/v2/books/{bookId}/alignment-report")
    suspend fun getAlignmentReport(@Path("bookId") bookId: String): Response<StorytellerAlignmentReportDto>

    @POST("api/v2/books/{bookId}/process")
    suspend fun startProcessing(
        @Path("bookId") bookId: String,
        @Query("restart") restart: String?,
        @Body body: RequestBody,
    ): Response<Unit>

    @DELETE("api/v2/books/{bookId}/process")
    suspend fun cancelProcessing(@Path("bookId") bookId: String): Response<Unit>
}
