package com.enve.silo.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class SiloLoginRequest(
    val username: String,
    val password: String,
)

@Serializable
data class SiloLoginResponse(
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String,
    val user: SiloUserDto,
)

@Serializable
data class SiloRefreshRequest(
    @SerialName("refresh_token") val refreshToken: String,
)

@Serializable
data class SiloRefreshResponse(
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String,
)

@Serializable
data class SiloUserDto(
    val id: Int,
    val username: String,
    val email: String? = null,
    val role: String? = null,
    val permissions: List<String> = emptyList(),
)

@Serializable
data class SiloAdminStatsDto(
    @SerialName("total_items") val totalItems: Int = 0,
    @SerialName("total_files") val totalFiles: Int = 0,
    @SerialName("total_users") val totalUsers: Int = 0,
    @SerialName("total_movies") val totalMovies: Int = 0,
    @SerialName("total_movie_files") val totalMovieFiles: Int = 0,
    @SerialName("total_shows") val totalShows: Int = 0,
    @SerialName("total_show_files") val totalShowFiles: Int = 0,
    @SerialName("active_streams") val activeStreams: Int = 0,
    @SerialName("total_storage_bytes") val totalStorageBytes: Long = 0,
)

@Serializable
data class SiloAdminServerStatusDto(
    @SerialName("started_at") val startedAt: String? = null,
    @SerialName("restart_required") val restartRequired: Boolean = false,
    @SerialName("restart_required_at") val restartRequiredAt: String? = null,
    @SerialName("restart_required_reason") val restartRequiredReason: String? = null,
    @SerialName("restart_requested") val restartRequested: Boolean = false,
    @SerialName("restart_requested_at") val restartRequestedAt: String? = null,
)

@Serializable
data class SiloAdminUserDto(
    val id: Int,
    val username: String,
    val email: String = "",
    val role: String = "user",
    val enabled: Boolean = true,
    @SerialName("last_active_at") val lastActiveAt: String? = null,
)

@Serializable
data class SiloProfilesResponse(
    val profiles: List<SiloProfileDto> = emptyList(),
)

@Serializable
data class SiloProfileDto(
    val id: String,
    val name: String,
    @SerialName("is_primary") val isPrimary: Boolean = false,
)

@Serializable
data class SiloLibraryDto(
    val id: Int,
    val name: String,
    val type: String,
)

@Serializable
data class SiloLibrariesEnvelope(
    val libraries: List<SiloLibraryDto>? = null,
    val items: List<SiloLibraryDto>? = null,
)

@Serializable
data class SiloCatalogResponse(
    val total: Int = 0,
    @SerialName("has_more") val hasMore: Boolean? = null,
    val items: List<SiloCatalogItemDto> = emptyList(),
)

@Serializable
data class SiloCatalogItemDto(
    @SerialName("content_id") val contentId: String,
    val type: String,
    @SerialName("poster_url") val posterUrl: String? = null,
)

@Serializable
data class SiloItemDetailDto(
    @SerialName("content_id") val contentId: String,
    val type: String,
    val title: String,
    val year: Int? = null,
    val overview: String? = null,
    val runtime: Int? = null,
    val genres: List<String>? = null,
    @SerialName("poster_url") val posterUrl: String? = null,
    @SerialName("series_title") val seriesTitle: String? = null,
    @SerialName("user_data") val userData: SiloProgressStateDto? = null,
    val versions: List<SiloFileVersionDto> = emptyList(),
    @SerialName("playback_variants") val playbackVariants: List<SiloPlaybackVariantDto>? = null,
    val audiobook: SiloAudiobookExtensionDto? = null,
    val ebook: SiloEbookExtensionDto? = null,
)

@Serializable
data class SiloPlaybackVariantDto(
    val parts: List<SiloPlaybackVariantPartDto> = emptyList(),
)

@Serializable
data class SiloPlaybackVariantPartDto(
    @SerialName("part_index") val partIndex: Int = 0,
    @SerialName("default_file_id") val defaultFileId: Int? = null,
    val versions: List<SiloFileVersionDto> = emptyList(),
)

@Serializable
data class SiloProgressStateDto(
    @SerialName("position_seconds") val positionSeconds: Double? = null,
    @SerialName("duration_seconds") val durationSeconds: Double? = null,
    val played: Boolean? = null,
)

@Serializable
data class SiloProgressListResponse(
    val progress: List<SiloProgressEntryDto> = emptyList(),
)

@Serializable
data class SiloProgressEntryDto(
    @SerialName("media_item_id") val mediaItemId: String,
    @SerialName("updated_at") val updatedAt: String? = null,
)

@Serializable
data class SiloAudiobookExtensionDto(
    val authors: List<SiloPersonDto> = emptyList(),
    val narrators: List<SiloPersonDto> = emptyList(),
    val publisher: String? = null,
    @SerialName("total_duration_seconds") val totalDurationSeconds: Int? = null,
    val series: SiloSeriesGroupDto? = null,
)

@Serializable
data class SiloEbookExtensionDto(
    val authors: List<SiloPersonDto> = emptyList(),
    val publisher: String? = null,
    val series: SiloSeriesGroupDto? = null,
)

@Serializable
data class SiloPersonDto(
    val name: String,
)

@Serializable
data class SiloSeriesGroupDto(
    val name: String? = null,
)

@Serializable
data class SiloFileVersionDto(
    @SerialName("file_id") val fileId: Int,
    @SerialName("file_name") val fileName: String? = null,
    @SerialName("file_path") val filePath: String? = null,
    val container: String? = null,
    @SerialName("file_size") val fileSize: Long? = null,
    val duration: Int? = null,
    val bitrate: Int? = null,
    val chapters: List<SiloChapterDto>? = null,
)

@Serializable
data class SiloChapterDto(
    val index: Int,
    val title: String,
    @SerialName("start_seconds") val startSeconds: Double,
    @SerialName("end_seconds") val endSeconds: Double,
)

@Serializable
data class SiloPlaybackStartRequest(
    @SerialName("file_id") val fileId: Int,
    @SerialName("profile_id") val profileId: String,
    @SerialName("play_method") val playMethod: String = "direct",
    @SerialName("disable_progress_persistence") val disableProgressPersistence: Boolean = false,
    @SerialName("codecs_audio") val audioCodecs: List<String> = listOf("aac", "mp3", "m4a", "m4b", "alac", "flac", "opus", "vorbis"),
    val containers: List<String> = listOf("mp3", "m4a", "m4b", "aac", "flac", "ogg", "opus", "wav"),
    @SerialName("max_resolution") val maxResolution: String = "original",
    val hdr: Boolean = true,
)

@Serializable
data class SiloPlaybackStartResponse(
    @SerialName("session_id") val sessionId: String,
    @SerialName("stream_url") val streamUrl: String,
    val position: Double? = null,
    @SerialName("duration_seconds") val durationSeconds: Double? = null,
)

@Serializable
data class SiloPlaybackProgressRequest(
    val position: Double,
    @SerialName("is_paused") val isPaused: Boolean,
)

@Serializable
data class SiloProgressSyncRequest(
    val items: List<SiloProgressSyncItem>,
)

@Serializable
data class SiloProgressSyncItem(
    @SerialName("media_item_id") val mediaItemId: String,
    val position: Double,
    val duration: Double,
    @SerialName("updated_at") val updatedAt: String,
)

@Serializable
data class SiloProgressSyncResponse(
    val results: List<SiloProgressSyncResult> = emptyList(),
)

@Serializable
data class SiloProgressSyncResult(
    @SerialName("media_item_id") val mediaItemId: String,
    val status: String = "",
)

@Serializable
data class SiloEbookProgressRequest(
    @SerialName("file_id") val fileId: Int,
    val location: String,
    val progress: Double,
)

@Serializable
data class SiloEbookProgressResponse(
    @SerialName("file_id") val fileId: Int? = null,
    val location: String? = null,
    val progress: Double? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

@Serializable
data class SiloReaderAnnotationsEnvelope(
    val items: List<SiloReaderAnnotationRecord> = emptyList(),
)

@Serializable
data class SiloReaderAnnotationRecord(
    val id: String,
    @SerialName("content_id") val contentId: String,
    val kind: String,
    @SerialName("cfi_range") val cfiRange: String? = null,
    val location: String? = null,
    @SerialName("selected_text") val selectedText: String = "",
    val note: String = "",
    val style: String = "highlight",
    val color: String = "#facc15",
    val metadata: Map<String, String> = emptyMap(),
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

@Serializable
data class SiloReaderAnnotationRequest(
    val kind: String,
    @SerialName("cfi_range") val cfiRange: String? = null,
    val location: String,
    @SerialName("selected_text") val selectedText: String,
    val note: String,
    val style: String,
    val color: String,
    val metadata: Map<String, String>,
)

@Serializable
data class SiloItemListResponse(
    val items: List<SiloItemListEntryDto> = emptyList(),
    @SerialName("has_more") val hasMore: Boolean = false,
)

@Serializable
data class SiloItemListEntryDto(
    @SerialName("content_id") val contentId: String,
    val type: String = "",
    val title: String = "",
    @SerialName("series_title") val seriesTitle: String? = null,
    val runtime: Int = 0,
)

@Serializable
data class SiloScoredItemsResponse(
    val items: List<SiloScoredItemDto> = emptyList(),
)

@Serializable
data class SiloScoredItemDto(
    @SerialName("media_item_id") val mediaItemId: String,
    val score: Double = 0.0,
    val reason: String = "",
    @SerialName("reason_detail") val reasonDetail: String? = null,
)
