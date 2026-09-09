package com.enve.bookorbit.dto

import kotlinx.serialization.Serializable

@Serializable
data class BookOrbitRecommendationDto(
    val id: Int,
    val title: String? = null,
    val updatedAt: String? = null,
    @Serializable(with = BookOrbitSeriesIndexSerializer::class)
    val seriesIndex: String? = null,
    val hasCover: Boolean = false,
    val authors: List<String> = emptyList(),
    val isAudiobook: Boolean = false,
    val isComic: Boolean = false,
)
