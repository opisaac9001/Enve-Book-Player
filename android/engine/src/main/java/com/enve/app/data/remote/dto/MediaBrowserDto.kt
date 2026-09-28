package com.enve.app.data.remote.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class MediaBrowserItemsDto(
    @SerialName("Items") val items: List<MediaBrowserItemDto>,
    @SerialName("TotalRecordCount") val totalRecordCount: Int,
)

@Serializable
data class MediaBrowserItemDto(
    @SerialName("Id") val id: String,
    @SerialName("Name") val name: String? = null,
    @SerialName("Type") val type: String,
    @SerialName("CollectionType") val collectionType: String? = null,
    @SerialName("ChildCount") val childCount: Int? = null,
    @SerialName("RunTimeTicks") val runTimeTicks: Long? = null,
    @SerialName("Overview") val overview: String? = null,
    @SerialName("People") val people: List<MediaBrowserPersonDto> = emptyList(),
    @SerialName("Composers") val composers: List<MediaBrowserNamedItemDto> = emptyList(),
    @SerialName("AlbumArtist") val albumArtist: String? = null,
    @SerialName("UserData") val userData: MediaBrowserUserDataDto? = null,
    @SerialName("ImageTags") val imageTags: Map<String, String> = emptyMap(),
    @SerialName("PrimaryImageItemId") val primaryImageItemId: String? = null,
    @SerialName("PrimaryImageTag") val primaryImageTag: String? = null,
    @SerialName("ParentPrimaryImageItemId") val parentPrimaryImageItemId: String? = null,
    @SerialName("ParentPrimaryImageTag") val parentPrimaryImageTag: String? = null,
    @SerialName("AlbumId") val albumId: String? = null,
    @SerialName("AlbumPrimaryImageTag") val albumPrimaryImageTag: String? = null,
)

@Serializable
data class MediaBrowserUserDataDto(
    @SerialName("PlaybackPositionTicks") val playbackPositionTicks: Long,
    @SerialName("PlayedPercentage") val playedPercentage: Double? = null,
    @SerialName("Played") val played: Boolean,
)

@Serializable
data class MediaBrowserPersonDto(
    @SerialName("Name") val name: String,
    @SerialName("Type") val type: String,
)

@Serializable
data class MediaBrowserNamedItemDto(
    @SerialName("Name") val name: String,
)
