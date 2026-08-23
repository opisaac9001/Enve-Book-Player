package com.enve.komga.api

import com.enve.komga.dto.KomgaBookDto
import com.enve.komga.dto.KomgaCollectionDto
import com.enve.komga.dto.KomgaLibraryDto
import com.enve.komga.dto.KomgaPage
import com.enve.komga.dto.KomgaReadListDto
import com.enve.komga.dto.KomgaReadProgressUpdateDto
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.PATCH
import retrofit2.http.POST
import retrofit2.http.PUT
import retrofit2.http.Path
import retrofit2.http.Query

interface KomgaApi {
    @GET("api/v1/libraries")
    suspend fun getLibraries(): Response<List<KomgaLibraryDto>>

    @GET("api/v1/books")
    suspend fun getBooks(
        @Query("library_id") libraryId: String? = null,
        @Query("read_status") readStatus: List<String>? = null,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 100,
        @Query("sort") sort: List<String>? = null,
        @Query("search") search: String? = null,
    ): Response<KomgaPage<KomgaBookDto>>

    @GET("api/v1/books/{bookId}")
    suspend fun getBook(
        @Path("bookId") bookId: String,
    ): Response<KomgaBookDto>

    @PATCH("api/v1/books/{bookId}/read-progress")
    suspend fun updateReadProgress(
        @Path("bookId") bookId: String,
        @Body request: KomgaReadProgressUpdateDto,
    ): Response<Unit>

    @PATCH("api/v1/books/{bookId}/metadata")
    suspend fun updateBookMetadata(
        @Path("bookId") bookId: String,
        @Body request: okhttp3.RequestBody,
    ): Response<Unit>

    @DELETE("api/v1/books/{bookId}/read-progress")
    suspend fun deleteReadProgress(
        @Path("bookId") bookId: String,
    ): Response<Unit>

    @GET("api/v1/books/{bookId}/file")
    suspend fun getBookFile(
        @Path("bookId") bookId: String,
    ): Response<okhttp3.ResponseBody>

    @GET("api/v1/books/{bookId}/pages/{pageNumber}")
    suspend fun getBookPage(
        @Path("bookId") bookId: String,
        @Path("pageNumber") pageNumber: Int,
    ): Response<okhttp3.ResponseBody>

    @GET("api/v1/books/ondeck")
    suspend fun getBooksOnDeck(
        @Query("library_id") libraryId: String? = null,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 40,
    ): Response<KomgaPage<KomgaBookDto>>

    @GET("api/v1/books/latest")
    suspend fun getBooksLatest(
        @Query("library_id") libraryId: String? = null,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 40,
    ): Response<KomgaPage<KomgaBookDto>>

    @GET("api/v1/series")
    suspend fun getSeries(
        @Query("library_id") libraryId: String? = null,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 100,
        @Query("search") search: String? = null,
    ): Response<KomgaPage<com.enve.komga.dto.KomgaSeriesDto>>

    @GET("api/v1/series/{seriesId}")
    suspend fun getSeriesDetail(
        @Path("seriesId") seriesId: String,
    ): Response<com.enve.komga.dto.KomgaSeriesDto>

    @GET("api/v1/series/{seriesId}/books")
    suspend fun getSeriesBooks(
        @Path("seriesId") seriesId: String,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 200,
        @Query("sort") sort: List<String>? = null,
    ): Response<KomgaPage<KomgaBookDto>>

    @GET("api/v1/series/latest")
    suspend fun getSeriesLatest(
        @Query("library_id") libraryId: String? = null,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 40,
    ): Response<KomgaPage<com.enve.komga.dto.KomgaSeriesDto>>

    @POST("api/v1/series/{seriesId}/read-progress")
    suspend fun markSeriesAsRead(
        @Path("seriesId") seriesId: String,
    ): Response<Unit>

    @DELETE("api/v1/series/{seriesId}/read-progress")
    suspend fun deleteSeriesReadProgress(
        @Path("seriesId") seriesId: String,
    ): Response<Unit>

    @GET("api/v1/authors")
    suspend fun getAuthors(
        @Query("search") search: String? = null,
    ): Response<List<com.enve.komga.dto.KomgaAuthorDto>>

    @GET("api/v1/readlists")
    suspend fun getReadLists(
        @Query("library_id") libraryId: String? = null,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 100,
    ): Response<KomgaPage<KomgaReadListDto>>

    @GET("api/v1/readlists/{readListId}/books")
    suspend fun getReadListBooks(
        @Path("readListId") readListId: String,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 500,
    ): Response<KomgaPage<KomgaBookDto>>

    @GET("api/v1/collections")
    suspend fun getCollections(
        @Query("library_id") libraryId: String? = null,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 100,
    ): Response<KomgaPage<KomgaCollectionDto>>

    @GET("api/v1/collections/{collectionId}/series")
    suspend fun getCollectionSeries(
        @Path("collectionId") collectionId: String,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 200,
    ): Response<KomgaPage<com.enve.komga.dto.KomgaSeriesDto>>

    @GET("api/v1/users/me")
    suspend fun getCurrentUser(): Response<com.enve.komga.dto.KomgaUserDto>

    @GET("api/v1/users")
    suspend fun adminListUsers(): Response<List<com.enve.komga.dto.KomgaUserDto>>

    @POST("api/v1/users")
    suspend fun adminCreateUser(
        @Body body: com.enve.komga.dto.KomgaUserCreationDto,
    ): Response<com.enve.komga.dto.KomgaUserDto>

    @DELETE("api/v1/users/{id}")
    suspend fun adminDeleteUser(@Path("id") id: String): Response<Unit>

    @PATCH("api/v1/users/{id}")
    suspend fun adminUpdateUser(
        @Path("id") id: String,
        @Body body: com.enve.komga.dto.KomgaUserUpdateDto,
    ): Response<Unit>

    @PATCH("api/v1/users/{id}/password")
    suspend fun adminUpdateUserPassword(
        @Path("id") id: String,
        @Body body: com.enve.komga.dto.KomgaPasswordUpdateDto,
    ): Response<Unit>

    @POST("api/v1/libraries")
    suspend fun adminCreateLibrary(
        @Body body: com.enve.komga.dto.KomgaLibraryCreationDto,
    ): Response<com.enve.komga.dto.KomgaLibraryDto>

    @PATCH("api/v1/libraries/{id}")
    suspend fun adminUpdateLibrary(
        @Path("id") id: String,
        @Body body: com.enve.komga.dto.KomgaLibraryUpdateDto,
    ): Response<Unit>

    @DELETE("api/v1/libraries/{id}")
    suspend fun adminDeleteLibrary(@Path("id") id: String): Response<Unit>

    @PUT("api/v1/libraries/{id}/scan")
    suspend fun adminScanLibrary(
        @Path("id") id: String,
        @Query("deep") deep: Boolean = false,
    ): Response<Unit>

    @PUT("api/v1/libraries/{id}/analyze")
    suspend fun adminAnalyzeLibrary(@Path("id") id: String): Response<Unit>

    @PUT("api/v1/libraries/{id}/metadata/refresh")
    suspend fun adminRefreshLibraryMetadata(@Path("id") id: String): Response<Unit>

    @PUT("api/v1/libraries/{id}/empty-trash")
    suspend fun adminEmptyLibraryTrash(@Path("id") id: String): Response<Unit>

    @POST("api/v1/collections")
    suspend fun adminCreateCollection(
        @Body body: com.enve.komga.dto.KomgaCollectionCreationDto,
    ): Response<KomgaCollectionDto>

    @PATCH("api/v1/collections/{id}")
    suspend fun adminUpdateCollection(
        @Path("id") id: String,
        @Body body: com.enve.komga.dto.KomgaCollectionUpdateDto,
    ): Response<Unit>

    @DELETE("api/v1/collections/{id}")
    suspend fun adminDeleteCollection(@Path("id") id: String): Response<Unit>

    @PUT("api/v1/readlists")
    suspend fun adminCreateReadList(
        @Body body: com.enve.komga.dto.KomgaReadListCreationDto,
    ): Response<KomgaReadListDto>

    @PATCH("api/v1/readlists/{id}")
    suspend fun adminUpdateReadList(
        @Path("id") id: String,
        @Body body: com.enve.komga.dto.KomgaReadListUpdateDto,
    ): Response<Unit>

    @DELETE("api/v1/readlists/{id}")
    suspend fun adminDeleteReadList(@Path("id") id: String): Response<Unit>

    @GET("actuator/info")
    suspend fun adminServerInfo(): Response<com.enve.komga.dto.KomgaActuatorInfoDto>

    @GET("api/v1/tasks")
    suspend fun adminListTasks(): Response<List<com.enve.komga.dto.KomgaTaskDto>>

    @GET("api/v1/announcements")
    suspend fun adminListAnnouncements(): Response<com.enve.komga.dto.KomgaAnnouncementsDto>

    @PUT("api/v1/announcements")
    suspend fun adminMarkAnnouncementsRead(
        @Body ids: List<String>,
    ): Response<Unit>

    @GET("api/v1/history")
    suspend fun adminListHistory(
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 100,
    ): Response<KomgaPage<com.enve.komga.dto.KomgaHistoryEventDto>>

    @GET("api/v1/api-keys")
    suspend fun adminListApiKeys(): Response<List<com.enve.komga.dto.KomgaApiKeyDto>>

    @POST("api/v1/api-keys")
    suspend fun adminCreateApiKey(
        @Body body: com.enve.komga.dto.KomgaApiKeyCreationDto,
    ): Response<com.enve.komga.dto.KomgaApiKeyDto>

    @DELETE("api/v1/api-keys/{id}")
    suspend fun adminDeleteApiKey(@Path("id") id: String): Response<Unit>
}
