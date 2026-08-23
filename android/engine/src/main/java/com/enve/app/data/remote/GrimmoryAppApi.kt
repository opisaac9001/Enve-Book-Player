package com.enve.app.data.remote

import com.enve.app.data.remote.dto.grimmoryapp.AppAuthorDetailDto
import com.enve.app.data.remote.dto.grimmoryapp.AppBookDetailDto
import com.enve.app.data.remote.dto.grimmoryapp.AppBookSummaryDto
import com.enve.app.data.remote.dto.grimmoryapp.AppFilterOptionsDto
import com.enve.app.data.remote.dto.grimmoryapp.AppLibrarySummaryDto
import com.enve.app.data.remote.dto.grimmoryapp.AppMagicShelfSummaryDto
import com.enve.app.data.remote.dto.grimmoryapp.AppPageDto
import com.enve.app.data.remote.dto.grimmoryapp.AppShelfSummaryDto
import com.enve.app.data.remote.dto.grimmoryapp.AppUserInfoDto
import com.enve.app.data.remote.dto.grimmoryapp.AudiobookInfoDto
import com.enve.app.data.remote.dto.grimmoryapp.AppAuthorSummaryDto
import com.enve.app.data.remote.dto.grimmoryapp.AppSeriesSummaryDto
import com.enve.app.data.remote.dto.grimmoryapp.UpdateRatingRequest
import com.enve.app.data.remote.dto.grimmoryapp.UpdateStatusRequest
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.PUT
import retrofit2.http.Path
import retrofit2.http.Query

interface GrimmoryAppApi {

    @GET("api/v1/app/libraries")
    suspend fun getLibraries(): Response<List<AppLibrarySummaryDto>>

    @GET("api/v1/app/books")
    suspend fun getBooks(
        @Query("libraryId") libraryId: Long? = null,
        @Query("shelfId") shelfId: Long? = null,
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
    ): Response<AppPageDto<AppBookSummaryDto>>

    @GET("api/v1/app/books/{bookId}")
    suspend fun getBookDetail(@Path("bookId") bookId: String): Response<AppBookDetailDto>

    @GET("api/v1/app/books/search")
    suspend fun searchBooks(
        @Query("q") query: String,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 20,
    ): Response<AppPageDto<AppBookSummaryDto>>

    @GET("api/v1/app/books/random")
    suspend fun getRandomBooks(
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 20,
        @Query("libraryId") libraryId: Long? = null,
    ): Response<AppPageDto<AppBookSummaryDto>>

    @GET("api/v1/app/books/continue-listening")
    suspend fun getContinueListening(@Query("limit") limit: Int = 10): Response<List<AppBookSummaryDto>>

    @GET("api/v1/app/books/continue-reading")
    suspend fun getContinueReading(@Query("limit") limit: Int = 10): Response<List<AppBookSummaryDto>>

    @GET("api/v1/app/books/recently-added")
    suspend fun getRecentlyAdded(@Query("limit") limit: Int = 10): Response<List<AppBookSummaryDto>>

    @GET("api/v1/app/books/recently-scanned")
    suspend fun getRecentlyScanned(@Query("limit") limit: Int = 10): Response<List<AppBookSummaryDto>>

    @GET("api/v1/app/series")
    suspend fun getSeries(
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 30,
        @Query("sort") sort: String = "name",
        @Query("dir") dir: String = "asc",
        @Query("libraryId") libraryId: Long? = null,
        @Query("search") search: String? = null,
        @Query("status") status: String? = null,
    ): Response<AppPageDto<AppSeriesSummaryDto>>

    @GET("api/v1/app/series/{seriesName}/books")
    suspend fun getSeriesBooks(
        @Path("seriesName") seriesName: String,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 30,
        @Query("sort") sort: String = "seriesNumber",
        @Query("dir") dir: String = "asc",
        @Query("libraryId") libraryId: Long? = null,
    ): Response<AppPageDto<AppBookSummaryDto>>

    @GET("api/v1/app/authors")
    suspend fun getAuthors(
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 30,
        @Query("sort") sort: String = "name",
        @Query("dir") dir: String = "asc",
        @Query("libraryId") libraryId: Long? = null,
        @Query("search") search: String? = null,
        @Query("hasPhoto") hasPhoto: Boolean? = null,
    ): Response<AppPageDto<AppAuthorSummaryDto>>

    @GET("api/v1/app/authors/{authorId}")
    suspend fun getAuthorDetail(@Path("authorId") authorId: String): Response<AppAuthorDetailDto>

    @GET("api/v1/app/filter-options")
    suspend fun getFilterOptions(
        @Query("libraryId") libraryId: Long? = null,
        @Query("shelfId") shelfId: Long? = null,
        @Query("magicShelfId") magicShelfId: Long? = null,
    ): Response<AppFilterOptionsDto>

    @GET("api/v1/app/shelves")
    suspend fun getShelves(): Response<List<AppShelfSummaryDto>>

    @GET("api/v1/app/shelves/magic")
    suspend fun getMagicShelves(): Response<List<AppMagicShelfSummaryDto>>

    @GET("api/v1/app/shelves/magic/{magicShelfId}/books")
    suspend fun getMagicShelfBooks(
        @Path("magicShelfId") magicShelfId: Long,
        @Query("page") page: Int = 0,
        @Query("size") size: Int = 30,
    ): Response<AppPageDto<AppBookSummaryDto>>

    @GET("api/v1/app/users/me")
    suspend fun getCurrentUser(): Response<AppUserInfoDto>

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
        @Query("bookType") bookType: String? = null,
    ): Response<AudiobookInfoDto>
}
