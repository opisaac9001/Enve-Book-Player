package com.enve.bookorbit.dto

import kotlinx.serialization.Serializable

@Serializable
data class BookOrbitLoginRequest(
    val username: String,
    val password: String,
)

@Serializable
data class BookOrbitLoginResponse(
    val accessToken: String,
)

@Serializable
data class BookOrbitOidcProviderDto(
    val slug: String,
    val displayName: String? = null,
    val enabled: Boolean = false,
    val clientId: String,
    val scopes: String,
)

@Serializable
data class BookOrbitOidcStateDto(
    val state: String,
    val authorizationEndpoint: String,
)

@Serializable
data class BookOrbitOidcCallbackRequest(
    val code: String,
    val codeVerifier: String,
    val redirectUri: String,
    val nonce: String,
    val state: String,
)

@Serializable
data class BookOrbitOidcTokenDto(
    val mode: String? = null,
    val accessToken: String,
    val user: BookOrbitUserDto,
)

@Serializable
data class BookOrbitUserDto(
    val id: Int,
    val username: String,
    val isSuperuser: Boolean = false,
)

@Serializable
data class BookOrbitCollectionDto(
    val id: Int,
    val name: String,
    val icon: String? = null,
    val description: String? = null,
    val syncToKobo: Boolean = false,
    val displayOrder: Int = 0,
    val bookCount: Int = 0,
    val memberCount: Int? = null,
)

@Serializable
data class BookOrbitCollectionRequest(
    val name: String,
    val icon: String,
    val description: String? = null,
    val syncToKobo: Boolean = false,
)

@Serializable
data class BookOrbitCollectionBooksRequest(val bookIds: List<Int>)

@Serializable
data class BookOrbitCollectionOrderItem(val id: Int, val displayOrder: Int)

@Serializable
data class BookOrbitCollectionOrderRequest(val order: List<BookOrbitCollectionOrderItem>)

@Serializable
data class BookOrbitLibraryDto(
    val id: Int,
    val name: String,
)

@Serializable
data class BookOrbitPaginationRequest(
    val page: Int,
    val size: Int,
)

@Serializable
data class BookOrbitBooksPageRequest(
    val pagination: BookOrbitPaginationRequest,
)

@Serializable
data class BookOrbitBooksPageDto(
    val items: List<BookOrbitBookCardDto> = emptyList(),
    val total: Int = 0,
    val page: Int = 0,
    val size: Int = 0,
)

@Serializable
data class BookOrbitFileDto(
    val id: Int,
    val format: String? = null,
    val role: String? = null,
    val durationSeconds: Double? = null,
    val filename: String? = null,
)

@Serializable
data class BookOrbitBookCardDto(
    val id: Int,
    val title: String? = null,
    val subtitle: String? = null,
    val authors: List<String> = emptyList(),
    val narrators: List<String> = emptyList(),
    val seriesName: String? = null,
    val seriesIndex: Double? = null,
    val publishedYear: Int? = null,
    val language: String? = null,
    val genres: List<String> = emptyList(),
    val tags: List<String> = emptyList(),
    val rating: Float? = null,
    val publisher: String? = null,
    val isbn13: String? = null,
    val pageCount: Int? = null,
    val hasCover: Boolean? = null,
    val addedAt: String? = null,
    val readStatus: BookOrbitReadStatusDto? = null,
    val files: List<BookOrbitFileDto> = emptyList(),
)

@Serializable
data class BookOrbitAuthorDto(
    val name: String,
)

@Serializable
data class BookOrbitNarratorDto(
    val name: String,
)

@Serializable
data class BookOrbitChapterDto(
    val title: String,
    val startMs: Double,
)

@Serializable
data class BookOrbitAudioMetadataDto(
    val narrators: List<BookOrbitNarratorDto> = emptyList(),
    val durationSeconds: Double? = null,
    val chapters: List<BookOrbitChapterDto> = emptyList(),
)

@Serializable
data class BookOrbitReadStatusDto(
    val status: String? = null,
)

@Serializable
data class BookOrbitBookDetailDto(
    val id: Int,
    val libraryId: Int? = null,
    val libraryName: String? = null,
    val title: String? = null,
    val subtitle: String? = null,
    val description: String? = null,
    val isbn13: String? = null,
    val publisher: String? = null,
    val publishedYear: Int? = null,
    val pageCount: Int? = null,
    val language: String? = null,
    val seriesName: String? = null,
    val seriesIndex: Double? = null,
    val authors: List<BookOrbitAuthorDto> = emptyList(),
    val genres: List<String> = emptyList(),
    val tags: List<String> = emptyList(),
    val rating: Float? = null,
    val addedAt: String? = null,
    val hasCover: Boolean? = null,
    val coverSource: String? = null,
    val files: List<BookOrbitFileDto> = emptyList(),
    val audioMetadata: BookOrbitAudioMetadataDto? = null,
    val readStatus: BookOrbitReadStatusDto? = null,
)

@Serializable
data class BookOrbitRatingRequest(
    val rating: Int,
)

@Serializable
data class BookOrbitCurrentlyReadingWidgetDto(
    val books: List<BookOrbitCurrentlyReadingBookDto> = emptyList(),
)

@Serializable
data class BookOrbitCurrentlyReadingBookDto(
    val bookId: Int,
    val progress: Double? = null,
    val fileFormat: String? = null,
    val fileId: Int? = null,
)

@Serializable
data class BookOrbitAudioProgressDto(
    val percentage: Double? = null,
    val currentFileId: Int? = null,
    val positionSeconds: Double? = null,
    val updatedAt: String? = null,
)

@Serializable
data class BookOrbitFileProgressDto(
    val cfi: String? = null,
    val percentage: Double? = null,
    val positionSeconds: Double? = null,
    val updatedAt: String? = null,
)

@Serializable
data class BookOrbitAudioProgressRequest(
    val percentage: Double,
    val currentFileId: Int,
    val positionSeconds: Double,
)

@Serializable
data class BookOrbitEbookProgressRequest(
    val percentage: Double,
    val cfi: String? = null,
)

@Serializable
data class BookOrbitStatusRequest(
    val status: String,
)

@Serializable
data class BookOrbitAnnotationDto(
    val id: Int,
    val bookId: Int,
    val cfi: String,
    val text: String,
    val color: String,
    val style: String,
    val note: String? = null,
    val chapterTitle: String? = null,
    val createdAt: String,
)

@Serializable
data class BookOrbitCreateAnnotationRequest(
    val cfi: String,
    val text: String,
    val color: String,
    val style: String,
    val note: String? = null,
    val chapterTitle: String? = null,
)

@Serializable
data class BookOrbitUpdateAnnotationRequest(
    val note: String? = null,
    val color: String,
    val style: String,
)

@Serializable
data class BookOrbitBookmarkDto(
    val id: Int,
    val bookId: Int,
    val cfi: String? = null,
    val title: String,
    val positionSeconds: Double? = null,
    val createdAt: String,
)

@Serializable
data class BookOrbitBookmarkRequest(
    val cfi: String? = null,
    val title: String,
    val positionSeconds: Double? = null,
)

@Serializable
data class BookOrbitReadingSessionRequest(
    val sessionId: String,
    val startedAt: String,
    val endedAt: String,
    val durationSeconds: Int,
    val progressDelta: Double? = null,
    val endProgress: Double? = null,
)

@Serializable
data class BookOrbitReadingSessionDto(
    val id: Int,
    val startedAt: String,
    val endedAt: String,
    val durationSeconds: Int,
    val progressDelta: Double? = null,
    val endProgress: Double? = null,
    val format: String? = null,
    val source: String? = null,
)

@Serializable
data class BookOrbitReadingSessionsPageDto(
    val items: List<BookOrbitReadingSessionDto> = emptyList(),
    val total: Int = 0,
    val page: Int = 1,
    val pageSize: Int = 100,
)
