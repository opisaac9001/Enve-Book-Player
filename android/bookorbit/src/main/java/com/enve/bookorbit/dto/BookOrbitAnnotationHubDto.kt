package com.enve.bookorbit.dto

import kotlinx.serialization.Serializable

@Serializable
data class BookOrbitAnnotationHubItemDto(
    val id: Int,
    val bookId: Int,
    val cfi: String? = null,
    val pageno: Int? = null,
    val text: String = "",
    val color: String = "",
    val style: String = "",
    val note: String? = null,
    val chapterTitle: String? = null,
    val origin: String? = null,
    val positionStatus: String? = null,
    val createdAt: String? = null,
    val deletedAt: String? = null,
    val bookTitle: String? = null,
    val author: String? = null,
)

@Serializable
data class BookOrbitAnnotationOriginCountDto(
    val origin: String,
    val count: Int = 0,
)

@Serializable
data class BookOrbitAnnotationHubStatsDto(
    val books: Int = 0,
    val withNotes: Int = 0,
    val originBreakdown: List<BookOrbitAnnotationOriginCountDto> = emptyList(),
)

@Serializable
data class BookOrbitAnnotationHubPageDto(
    val items: List<BookOrbitAnnotationHubItemDto> = emptyList(),
    val total: Int = 0,
    val page: Int = 1,
    val pageSize: Int = 25,
    val stats: BookOrbitAnnotationHubStatsDto = BookOrbitAnnotationHubStatsDto(),
)

@Serializable
data class BookOrbitAnnotationBookFacetDto(
    val bookId: Int,
    val bookTitle: String? = null,
    val author: String? = null,
    val count: Int = 0,
)

@Serializable
data class BookOrbitAnnotationBulkRequest(
    val ids: List<Int>,
    val action: String,
    val color: String? = null,
    val style: String? = null,
)

@Serializable
data class BookOrbitAnnotationBulkResultDto(
    val affected: Int = 0,
)
