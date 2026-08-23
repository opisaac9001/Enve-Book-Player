package com.enve.plex.api

import com.enve.plex.dto.PlexItemResponse
import com.enve.plex.dto.PlexItemsResponse
import com.enve.plex.dto.PlexSectionsResponse
import retrofit2.Response
import retrofit2.http.GET
import retrofit2.http.Path
import retrofit2.http.Query

interface PlexApi {

    @GET("library/sections")
    suspend fun getSections(): Response<PlexSectionsResponse>

    @GET("library/sections/{sectionId}/all")
    suspend fun getSectionItems(
        @Path("sectionId") sectionId: String,
        @Query("type") type: Int? = 9,
        @Query("includeMedia") includeMedia: Int = 1,
        @Query("sort") sort: String? = null,
        @Query("X-Plex-Container-Start") start: Int = 0,
        @Query("X-Plex-Container-Size") size: Int = 100,
    ): Response<PlexItemsResponse>

    @GET("library/metadata/{ratingKey}")
    suspend fun getMetadata(
        @Path("ratingKey") ratingKey: String,
        @Query("includeChapters") includeChapters: Int = 1,
    ): Response<PlexItemResponse>

    @GET("library/metadata/{ratingKey}/children")
    suspend fun getMetadataChildren(
        @Path("ratingKey") ratingKey: String,
        @Query("includeMedia") includeMedia: Int = 1,
    ): Response<PlexItemsResponse>

    @GET("library/onDeck")
    suspend fun getOnDeck(
        @Query("X-Plex-Container-Size") size: Int = 50,
    ): Response<PlexItemsResponse>

    @GET(":/progress")
    suspend fun reportProgress(
        @Query("key") ratingKey: String,
        @Query("identifier") identifier: String = "com.plexapp.plugins.library",
        @Query("time") timeMs: Long,
        @Query("state") state: String = "stopped",
    ): Response<Unit>

    @GET(":/scrobble")
    suspend fun scrobble(
        @Query("key") ratingKey: String,
        @Query("identifier") identifier: String = "com.plexapp.plugins.library",
    ): Response<Unit>

    @GET(":/unscrobble")
    suspend fun unscrobble(
        @Query("key") ratingKey: String,
        @Query("identifier") identifier: String = "com.plexapp.plugins.library",
    ): Response<Unit>
}
