package com.enve.bookorbit.dto

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable

@Serializable
data class BookOrbitSmartScopeDto(
    val id: Int,
    val name: String = "",
    val icon: String? = null,
    val isPublic: Boolean = false,
    val isOwner: Boolean = false,
    val displayOrder: Int = 0,
    val bookCount: Int? = null,
)

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class BookOrbitSmartScopeBooksRequest(
    @EncodeDefault(EncodeDefault.Mode.ALWAYS) val sort: List<BookOrbitSort> = emptyList(),
    val pagination: BookOrbitPaginationRequest,
    @EncodeDefault(EncodeDefault.Mode.NEVER) val q: String? = null,
)
