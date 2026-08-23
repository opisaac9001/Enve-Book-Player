package com.enve.core.data.remote.dto

import kotlinx.serialization.Serializable

@Serializable
data class SeriesSummaryDto(
    val name: String,
    val bookCount: Int? = null,
    val bookIds: List<String>? = null,
    val id: String? = null,
    val coverUrl: String? = null,
)

@Serializable
data class AuthorSummaryDto(
    val id: String,
    val name: String,
    val photoUrl: String? = null,
    val bookCount: Int? = null,
)

@Serializable
data class CollectionSummaryDto(
    val id: String,
    val name: String,
    val bookCount: Int = 0,
)
