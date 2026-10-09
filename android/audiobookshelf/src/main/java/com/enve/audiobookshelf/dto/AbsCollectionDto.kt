package com.enve.audiobookshelf.dto

import kotlinx.serialization.Serializable

@Serializable
data class AbsCollectionsResponse(
    val results: List<AbsCollectionDto>? = null,
    val collections: List<AbsCollectionDto>? = null,
) {
    val items: List<AbsCollectionDto> get() = results ?: collections.orEmpty()
}

@Serializable
data class AbsCollectionDto(
    val id: String,
    val name: String,
    val libraryId: String? = null,
    val books: List<AbsCollectionBookDto>? = null,
)

@Serializable
data class AbsCollectionBookDto(val id: String)

@Serializable
data class AbsCreateCollectionRequest(
    val libraryId: String,
    val name: String,
    val books: List<String>,
)

@Serializable
data class AbsCollectionBookRequest(val id: String)
