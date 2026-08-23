package com.enve.app.data.remote.dto.grimmoryapp

import com.enve.app.data.remote.dto.FlexibleIdSerializer
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonNames
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.time.Instant
import java.time.OffsetDateTime

@Serializable
data class AppPageDto<T>(
    val content: List<T> = emptyList(),
    val page: Int = 0,
    val size: Int = 0,
    val totalElements: Long = 0,
    val totalPages: Int = 0,
    val hasNext: Boolean = false,
    val hasPrevious: Boolean = false,
)

@Serializable
data class AppLibrarySummaryDto(
    val id: Long,
    val name: String,
    val bookCount: Int = 0,
    val allowedFormats: List<String> = emptyList(),
    val paths: List<String> = emptyList(),
)

@Serializable
data class AppBookSummaryDto(
    @Serializable(with = FlexibleIdSerializer::class) val id: String,
    val title: String = "",
    val authors: List<String> = emptyList(),
    val thumbnailUrl: String? = null,
    val readStatus: String? = null,
    val personalRating: Float? = null,
    val seriesName: String? = null,
    val seriesNumber: String? = null,
    val libraryId: Long? = null,
    @Serializable(with = FlexibleEpochMillisSerializer::class) val addedOn: Long = 0L,
    @Serializable(with = FlexibleEpochMillisSerializer::class) val lastReadTime: Long = 0L,
    val readProgress: Float = 0f,
    val primaryFileType: String? = null,
    val primaryFileName: String? = null,
    val fileTypes: List<String> = emptyList(),
    val files: List<AppBookFileDto> = emptyList(),
    val primaryFile: AppBookFileDto? = null,
    @Serializable(with = FlexibleEpochMillisSerializer::class) val coverUpdatedOn: Long = 0L,
    @Serializable(with = FlexibleEpochMillisSerializer::class) val audiobookCoverUpdatedOn: Long = 0L,
    val isPhysical: Boolean = false,
    val publishedDate: String? = null,
    val goodreadsRating: Float? = null,
    val publisher: String? = null,
    val categories: List<String> = emptyList(),
    val language: String? = null,
    val narrator: String? = null,
    val isbn13: String? = null,
    val isbn10: String? = null,
    val pageCount: Int? = null,
)

@Serializable
data class AppBookDetailDto(
    val id: String,
    val title: String = "",
    val authors: List<String> = emptyList(),
    val thumbnailUrl: String? = null,
    val readStatus: String? = null,
    val personalRating: Float? = null,
    val seriesName: String? = null,
    val seriesNumber: String? = null,
    val libraryId: Long? = null,
    val libraryName: String? = null,
    @Serializable(with = FlexibleEpochMillisSerializer::class) val addedOn: Long = 0L,
    @Serializable(with = FlexibleEpochMillisSerializer::class) val lastReadTime: Long = 0L,
    val readProgress: Float = 0f,
    val primaryFileType: String? = null,
    val isPhysical: Boolean = false,
    val subtitle: String? = null,
    val description: String? = null,
    val categories: List<String> = emptyList(),
    val publisher: String? = null,
    val publishedDate: String? = null,
    val pageCount: Int? = null,
    val isbn13: String? = null,
    val language: String? = null,
    val goodreadsRating: Float? = null,
    val goodreadsReviewCount: Int? = null,
    val shelves: List<AppShelfSummaryDto> = emptyList(),
    val fileTypes: List<String> = emptyList(),
    val files: List<AppBookFileDto> = emptyList(),
    val epubProgress: AppEpubProgressDto? = null,
    val pdfProgress: AppPdfProgressDto? = null,
    val cbxProgress: AppCbxProgressDto? = null,
    val audiobookProgress: AppAudiobookProgressDto? = null,
)

@Serializable
data class AppBookFileDto(
    val id: String? = null,
    val fileName: String? = null,
    val filePath: String? = null,
    val fileSubPath: String? = null,
    val fileType: String? = null,
    val bookType: String? = null,
    @SerialName("extension") val fileExtension: String? = null,
    val isPrimary: Boolean? = null,
    val primary: Boolean? = null,
    val sizeBytes: Long = 0,
) {
    val resolvedType: String?
        get() = bookType ?: fileType ?: fileExtension
}

@Serializable
data class AppEpubProgressDto(
    val cfi: String? = null,
    val href: String? = null,
    val percentage: Float = 0f,
    @Serializable(with = FlexibleEpochMillisSerializer::class) val updatedAt: Long = 0L,
)

@Serializable
data class AppPdfProgressDto(
    val page: Int = 0,
    val percentage: Float = 0f,
    @Serializable(with = FlexibleEpochMillisSerializer::class) val updatedAt: Long = 0L,
)

@Serializable
data class AppCbxProgressDto(
    val page: Int = 0,
    val percentage: Float = 0f,
    @Serializable(with = FlexibleEpochMillisSerializer::class) val updatedAt: Long = 0L,
)

@Serializable
data class AppAudiobookProgressDto(
    val positionMs: Long = 0L,
    val trackIndex: Int = 0,
    val percentage: Float = 0f,
    @Serializable(with = FlexibleEpochMillisSerializer::class) val updatedAt: Long = 0L,
)

@Serializable
data class AppSeriesSummaryDto(
    val seriesName: String,
    val bookCount: Int = 0,
    val seriesTotal: Int? = null,
    val authors: List<String> = emptyList(),
    val booksRead: Int = 0,
    @Serializable(with = FlexibleEpochMillisSerializer::class) val latestAddedOn: Long = 0L,
    val coverBooks: List<SeriesCoverBookDto> = emptyList(),
)

@Serializable
data class SeriesCoverBookDto(
    val id: String,
    val thumbnailUrl: String? = null,
    @Serializable(with = FlexibleEpochMillisSerializer::class) val coverUpdatedOn: Long = 0L,
)

@Serializable
data class AppAuthorSummaryDto(
    val id: String,
    val name: String,
    val asin: String? = null,
    val bookCount: Int = 0,
    val hasPhoto: Boolean = false,
)

@Serializable
data class AppAuthorDetailDto(
    val id: String,
    val name: String,
    val description: String? = null,
    val asin: String? = null,
    val bookCount: Int = 0,
    val hasPhoto: Boolean = false,
)

@Serializable
data class AppShelfSummaryDto(
    val id: Long,
    val name: String,
    val icon: String? = null,
    val bookCount: Int = 0,
    val publicShelf: Boolean = false,
)

@Serializable
data class AppMagicShelfSummaryDto(
    val id: Long,
    val name: String,
    val icon: String? = null,
    val iconType: String? = null,
    val publicShelf: Boolean = false,
)

@Serializable
data class AppFilterOptionsDto(
    val authors: List<NamedCountDto> = emptyList(),
    val narrators: List<NamedCountDto> = emptyList(),
    val categories: List<NamedCountDto> = emptyList(),
    val languages: List<LanguageOptionDto> = emptyList(),
    val readStatuses: List<NamedCountDto> = emptyList(),
    val fileTypes: List<NamedCountDto> = emptyList(),
    val publishers: List<NamedCountDto> = emptyList(),
)

@Serializable
data class NamedCountDto(val name: String, val count: Int = 0)

@Serializable
data class LanguageOptionDto(val code: String, val label: String, val count: Int = 0)

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class AppUserInfoDto(

    @SerialName("admin") @JsonNames("isAdmin") val isAdmin: Boolean = false,
    val canUpload: Boolean = false,
    val canDownload: Boolean = false,
    val canAccessBookdrop: Boolean = false,
    val maxFileUploadSizeMb: Int? = null,
)

@Serializable
data class AudiobookInfoDto(
    val bookId: String,
    val bookFileId: String? = null,
    val title: String? = null,
    val author: String? = null,
    val narrator: String? = null,
    val durationMs: Long = 0L,
    val bitrate: Int? = null,
    val codec: String? = null,
    val sampleRate: Int? = null,
    val channels: Int? = null,
    val totalSizeBytes: Long = 0L,
    val folderBased: Boolean = false,
    val chapters: List<AudiobookChapterDto> = emptyList(),
    val tracks: List<AudiobookTrackDto> = emptyList(),
)

@Serializable
data class AudiobookChapterDto(
    val index: Int,
    val title: String? = null,
    val startTimeMs: Long = 0L,
    val endTimeMs: Long = 0L,
    val durationMs: Long = 0L,
)

@Serializable
data class AudiobookTrackDto(
    val index: Int,
    val fileName: String? = null,
    val title: String? = null,
    val durationMs: Long? = null,
    val fileSizeBytes: Long? = null,
    val cumulativeStartMs: Long? = null,
)

@Serializable
data class UpdateStatusRequest(val status: String)

@Serializable
data class UpdateRatingRequest(val ids: List<Long>, val rating: Int)

internal object FlexibleEpochMillisSerializer : KSerializer<Long> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("FlexibleEpochMillis", PrimitiveKind.LONG)

    override fun deserialize(decoder: Decoder): Long {
        val jd = decoder as? JsonDecoder ?: return decoder.decodeLong()
        val element = jd.decodeJsonElement()
        if (element is JsonNull) return 0L
        val primitive = element as? JsonPrimitive ?: return 0L
        primitive.longOrNull?.let { return it }
        primitive.doubleOrNull?.let { return it.toLong() }
        val str = primitive.contentOrNull?.takeIf { it.isNotBlank() } ?: return 0L
        str.toLongOrNull()?.let { return it }
        return runCatching { OffsetDateTime.parse(str).toInstant().toEpochMilli() }
            .recoverCatching { Instant.parse(str).toEpochMilli() }
            .getOrElse { 0L }
    }

    override fun serialize(encoder: Encoder, value: Long) {
        encoder.encodeLong(value)
    }
}
