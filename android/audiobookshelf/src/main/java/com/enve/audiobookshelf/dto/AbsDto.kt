package com.enve.audiobookshelf.dto

import com.enve.core.data.remote.dto.AbsUserDto
import kotlinx.serialization.Serializable

@Serializable
data class AbsLibrariesResponse(
    val libraries: List<AbsLibraryDto> = emptyList(),
)

@Serializable
data class AbsLibraryDto(
    val id: String,
    val name: String,
    val icon: String? = null,
    val mediaType: String? = null,
)

@Serializable
data class AbsLibraryItemsResponse(
    val results: List<AbsLibraryItemDto> = emptyList(),
    val libraryItems: List<AbsLibraryItemDto> = emptyList(),
    val total: Int? = null,
    val limit: Int? = null,
    val page: Int? = null,
) {
    val items: List<AbsLibraryItemDto>
        get() = if (results.isNotEmpty()) results else libraryItems
}

@Serializable
data class AbsLibraryItemDto(
    val id: String,
    val libraryId: String? = null,
    val addedAt: Long? = null,
    val mediaType: String? = null,
    val media: AbsMediaDto? = null,
    val mediaProgress: AbsMediaProgressDto? = null,
)

@Serializable
data class AbsMediaDto(
    val metadata: AbsMetadataDto? = null,
    val coverPath: String? = null,
    val duration: Double? = null,
    val numTracks: Int? = null,
    val numAudioFiles: Int? = null,
    val ebookFormat: String? = null,
    val audioFiles: List<AbsAudioFileDto>? = null,
    val ebookFile: AbsEbookFileDto? = null,

    val chapters: List<AbsChapter>? = null,
)

@Serializable
data class AbsFileMetadataDto(
    val filename: String? = null,
    val ext: String? = null,
    val size: Long? = null,
)

@Serializable
data class AbsAudioFileDto(
    val index: Int? = null,
    val ino: String? = null,
    val metadata: AbsFileMetadataDto? = null,
    val duration: Double? = null,
    val mimeType: String? = null,
    val codec: String? = null,
    val bitRate: Int? = null,
    val channels: Int? = null,
)

@Serializable
data class AbsEbookFileDto(
    val ino: String? = null,
    val ebookFormat: String? = null,
    val metadata: AbsFileMetadataDto? = null,
)

@Serializable
data class AbsMetadataDto(
    val title: String? = null,
    val subtitle: String? = null,
    val authors: List<AbsAuthorDto>? = null,
    val authorName: String? = null,
    val narratorName: String? = null,
    val seriesName: String? = null,
    val seriesNumber: String? = null,
    val description: String? = null,
)

@Serializable
data class AbsAuthorDto(
    val id: String? = null,
    val name: String? = null,
)

@Serializable
data class AbsMetadataUpdateRequest(
    val metadata: AbsMetadataUpdatePayload,
)

@Serializable
data class AbsMetadataUpdatePayload(
    val title: String? = null,
    val subtitle: String? = null,
    val authors: List<AbsAuthorPayload>? = null,
    val narrators: List<String>? = null,
    val series: List<AbsSeriesPayload>? = null,
    val genres: List<String>? = null,
    val publishedYear: String? = null,
    val publishedDate: String? = null,
    val publisher: String? = null,
    val description: String? = null,
    val isbn: String? = null,
    val language: String? = null,
)

@Serializable
data class AbsAuthorPayload(
    val id: String? = null,
    val name: String,
)

@Serializable
data class AbsSeriesPayload(
    val id: String? = null,
    val name: String,
    val sequence: String? = null,
)

@Serializable
data class AbsMediaProgressDto(
    val id: String? = null,
    val libraryItemId: String? = null,
    val duration: Double? = null,
    val progress: Float? = null,
    val currentTime: Double? = null,
    val isFinished: Boolean? = null,
    val lastUpdate: Long? = null,
    val ebookLocation: String? = null,
    val ebookProgress: Float? = null,
)

@Serializable
data class AbsChaptersResponse(
    val chapters: List<AbsChapter>? = null,
)

@Serializable
data class AbsChapter(
    val id: kotlinx.serialization.json.JsonElement? = null,
    val title: String? = null,
    val start: Double? = null,
    val end: Double? = null,
    val startOffset: Double? = null,
)

@Serializable
data class AbsAuthorsResponse(
    val authors: List<AbsAuthorSummaryDto> = emptyList(),
)

@Serializable
data class AbsAuthorSummaryDto(
    val id: String,
    val name: String,
    val description: String? = null,
    val imagePath: String? = null,
    val numBooks: Int? = null,
)

@Serializable
data class AbsSeriesResponse(
    val series: List<AbsSeriesSummaryDto> = emptyList(),
)

@Serializable
data class AbsSeriesSummaryDto(
    val id: String,
    val name: String,
    val description: String? = null,
    val books: List<AbsLibraryItemDto>? = null,
)

@Serializable
data class AbsPlaybackSessionDto(
    val id: String,
    val libraryItemId: String? = null,
    val duration: Double? = null,
    val currentTime: Double? = null,
    val audioTracks: List<AbsPlaybackTrackDto> = emptyList(),
    val chapters: List<AbsChapter> = emptyList(),
)

@Serializable
data class AbsPlaybackTrackDto(
    val index: Int? = null,
    val startOffset: Double? = null,
    val duration: Double? = null,
    val title: String? = null,
    val contentUrl: String? = null,
    val mimeType: String? = null,
    val codec: String? = null,
    val metadata: AbsFileMetadataDto? = null,
)

@Serializable
data class AbsProgressUpdateRequest(
    val currentTime: Double? = null,
    val duration: Double? = null,
    val progress: Float? = null,
    val isFinished: Boolean? = null,
    val ebookLocation: String? = null,
    val ebookProgress: Float? = null,
)

@Serializable
data class AbsPlaybackSessionUpdateRequest(
    val currentTime: Double,
    val timeListened: Double,
    val duration: Double,
)

@Serializable
data class AbsPlaybackStartRequest(
    val deviceInfo: AbsPlaybackDeviceInfo = AbsPlaybackDeviceInfo(),
    val supportedMimeTypes: List<String> = listOf(
        "audio/mpeg",
        "audio/mp4",
        "audio/x-m4a",
        "audio/aac",
        "audio/flac",
        "audio/ogg",
        "audio/webm",
    ),
    val mediaPlayer: String = "Enve Android",
    val forceDirectPlay: Boolean = true,
)

@Serializable
data class AbsPlaybackDeviceInfo(
    val clientName: String = "Enve",
    val deviceId: String = "enve-android",
    val deviceName: String = "Android",
)

@Serializable
data class AbsBookmarkDto(
    val libraryItemId: String? = null,
    val title: String = "",
    val time: Double = 0.0,
    val createdAt: Long? = null,
)

@Serializable
data class AbsBookmarkRequest(
    val title: String,
    val time: Double,
)

@Serializable
data class AbsMeResponse(
    val bookmarks: List<AbsBookmarkDto> = emptyList(),
    val mediaProgress: List<AbsMediaProgressDto> = emptyList(),
)

@Serializable
data class AbsListeningStatsDto(
    val totalTime: Double = 0.0,
    val today: Double = 0.0,
    val days: Map<String, Double> = emptyMap(),
    val dayOfWeek: Map<String, Double> = emptyMap(),
)
