package com.enve.app.data.remote.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class TorBoxListResponseDto(
    val data: List<TorBoxDownloadDto>? = null,
)

@Serializable
data class TorBoxDownloadDto(
    val id: Long,
    val hash: String? = null,
    val name: String? = null,
    @SerialName("download_present") val downloadPresent: Boolean? = null,
    @SerialName("download_finished") val downloadFinished: Boolean? = null,
    val files: List<TorBoxFileDto> = emptyList(),
)

@Serializable
data class TorBoxFileDto(
    val id: Long,
    val name: String? = null,
    @SerialName("short_name") val shortName: String? = null,
    val size: Long? = null,
    @SerialName("s3_path") val s3Path: String? = null,
)
