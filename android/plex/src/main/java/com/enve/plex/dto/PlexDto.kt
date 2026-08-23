package com.enve.plex.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class PlexSectionsResponse(
    @SerialName("MediaContainer") val mediaContainer: PlexSectionsContainer,
)

@Serializable
data class PlexSectionsContainer(
    @SerialName("Directory") val directory: List<PlexSection> = emptyList(),
    val size: Int = 0,
)

@Serializable
data class PlexSection(
    val key: String,
    val title: String,
    val type: String,
    val agent: String? = null,
    val scanner: String? = null,
    val language: String? = null,
    val uuid: String? = null,
    val updatedAt: Long? = null,
)

@Serializable
data class PlexItemsResponse(
    @SerialName("MediaContainer") val mediaContainer: PlexItemsContainer,
)

@Serializable
data class PlexItemsContainer(
    @SerialName("Metadata") val metadata: List<PlexMetadata> = emptyList(),
    val totalSize: Int = 0,
    val size: Int = 0,
    val offset: Int = 0,
)

@Serializable
data class PlexItemResponse(
    @SerialName("MediaContainer") val mediaContainer: PlexItemContainer,
)

@Serializable
data class PlexItemContainer(
    @SerialName("Metadata") val metadata: List<PlexMetadata> = emptyList(),
)

@Serializable
data class PlexMetadata(
    val ratingKey: String,
    val key: String? = null,
    val type: String,
    val title: String,
    val titleSort: String? = null,
    val parentRatingKey: String? = null,
    val parentTitle: String? = null,
    val grandparentRatingKey: String? = null,
    val grandparentTitle: String? = null,
    val summary: String? = null,
    val thumb: String? = null,
    val parentThumb: String? = null,
    val grandparentThumb: String? = null,
    val duration: Long? = null,
    val viewOffset: Long? = null,
    val viewCount: Int? = null,
    val lastViewedAt: Long? = null,
    val addedAt: Long? = null,
    val leafCount: Int? = null,
    val index: Int? = null,
    val parentIndex: Int? = null,
    @SerialName("Media") val media: List<PlexMedia> = emptyList(),
    @SerialName("Chapter") val chapter: List<PlexChapter> = emptyList(),
)

@Serializable
data class PlexMedia(
    val id: Long? = null,
    val duration: Long? = null,
    val container: String? = null,
    val audioCodec: String? = null,
    @SerialName("Part") val part: List<PlexPart> = emptyList(),
)

@Serializable
data class PlexPart(
    val id: Long,
    val key: String,
    val duration: Long? = null,
    val file: String? = null,
    val container: String? = null,
)

@Serializable
data class PlexChapter(
    val id: Long? = null,
    val tag: String? = null,
    val title: String? = null,
    val startTimeOffset: Long = 0L,
    val endTimeOffset: Long = 0L,
)
