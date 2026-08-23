package com.enve.app.data.offline

import kotlinx.serialization.Serializable

@Serializable
data class OfflineAudioTrackManifest(
    val index: Int,
    val title: String? = null,
    val durationMs: Long = 0L,
    val relativePath: String,
    val bytes: Long = 0L,
)

@Serializable
data class OfflineAudioManifest(
    val bookId: String,
    val title: String,
    val author: String? = null,
    val coverUrl: String? = null,
    val source: String,
    val downloadedAtEpochMs: Long,
    val tracks: List<OfflineAudioTrackManifest>,
)

enum class OfflineDownloadStatus {
    QUEUED,
    DOWNLOADING,
    COMPLETED,
    FAILED,
    CANCELLED,
}

data class OfflineDownloadProgress(
    val bookId: String,
    val title: String,
    val status: OfflineDownloadStatus,
    val progress: Float,
    val downloadedBytes: Long,
    val totalBytes: Long,
    val completedTracks: Int,
    val totalTracks: Int,
    val errorMessage: String? = null,
)

data class OfflineTrackInfo(
    val uri: String,
    val title: String?,
    val durationMs: Long,
)
