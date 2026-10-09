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
    @SerialName("protocol_version") val protocolVersion: Int = 3,
    @SerialName("client_features") val clientFeatures: List<String> = emptyList(),
    @SerialName("file_id") val fileId: Int,
    @SerialName("profile_id") val profileId: String,
    @SerialName("playback_attempt_id") val playbackAttemptId: String,
    @SerialName("quality_preference") val qualityPreference: String = "original",
    @SerialName("subtitle_fidelity_preference") val subtitleFidelityPreference: String = "compatible",
    @SerialName("progress_persistence") val progressPersistence: String = "server",
    @SerialName("start_position") val startPosition: Double? = null,
    @SerialName("client_capabilities") val clientCapabilities: SiloAudioCapabilities = SiloAudioCapabilities(),
    @SerialName("client_playback_context") val playbackContext: SiloPlaybackContext = SiloPlaybackContext(),
)

@Serializable
data class SiloAudioCapabilities(
    @SerialName("video_evidence") val videoEvidence: String = "declared",
    @SerialName("audio_evidence") val audioEvidence: String = "declared",
    @SerialName("codecs_audio") val audioCodecs: List<String> = listOf("aac", "mp3"),
    val containers: List<String> = listOf("mp3", "m4a", "m4b", "aac", "mp4"),
    val hdr: Boolean = false,
)

@Serializable
data class SiloPlaybackContext(
    @SerialName("protocol_version") val protocolVersion: Int = 3,
    @SerialName("form_factor") val formFactor: String = "phone",
    val device: SiloPlaybackDevice = SiloPlaybackDevice(),
    val deliveries: Map<String, SiloAudioDelivery> = mapOf("original_http" to SiloAudioDelivery()),
)

@Serializable
data class SiloPlaybackDevice(val platform: String = "android")

@Serializable
data class SiloAudioDelivery(
    val enabled: Boolean = true,
    @SerialName("supported_on_device") val supportedOnDevice: Boolean = true,
    val containers: List<String> = listOf("mp3", "m4a", "m4b", "aac", "mp4"),
    @SerialName("audio_decode_codecs") val audioDecodeCodecs: List<String> = listOf("aac", "mp3"),
    @SerialName("audio_passthrough_codecs") val audioPassthroughCodecs: List<String> = emptyList(),
    val subtitles: SiloSubtitleCapabilities = SiloSubtitleCapabilities(),
    val features: List<String> = emptyList(),
    @SerialName("auth_header_refresh") val authHeaderRefresh: Boolean = false,
    @SerialName("validated_claims") val validatedClaims: List<String> = emptyList(),
    val transformations: List<String> = emptyList(),
)

@Serializable
data class SiloSubtitleCapabilities(
    @SerialName("embedded_text") val embeddedText: Boolean = false,
    @SerialName("sidecar_text") val sidecarText: Boolean = false,
    @SerialName("ass_styling") val assStyling: Boolean = false,
    @SerialName("embedded_bitmap") val embeddedBitmap: Boolean = false,
    @SerialName("sidecar_bitmap") val sidecarBitmap: Boolean = false,
    @SerialName("font_attachments") val fontAttachments: Boolean = false,
)

@Serializable
data class SiloPlaybackStartResponse(
    @SerialName("protocol_version") val protocolVersion: Int,
    val outcome: String,
    @SerialName("session_id") val sessionId: String? = null,
    @SerialName("playback_plan") val playbackPlan: SiloPlaybackPlan? = null,
    val terminal: SiloPlaybackTerminal? = null,
)

@Serializable
data class SiloPlaybackPlan(
    @SerialName("protocol_version") val protocolVersion: Int,
    val delivery: String,
    val stream: SiloPlaybackStream,
    val timeline: SiloPlaybackTimeline,
    val source: SiloPlaybackSource,
)

@Serializable
data class SiloPlaybackStream(val url: String, val protocol: String)

@Serializable
data class SiloPlaybackTimeline(
    @SerialName("source_start_seconds") val sourceStartSeconds: Double,
    @SerialName("player_start_seconds") val playerStartSeconds: Double,
    @SerialName("timeline_offset_seconds") val timelineOffsetSeconds: Double,
)

@Serializable
data class SiloPlaybackSource(@SerialName("duration_seconds") val durationSeconds: Double? = null)

@Serializable
data class SiloPlaybackTerminal(val reason: String)

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
