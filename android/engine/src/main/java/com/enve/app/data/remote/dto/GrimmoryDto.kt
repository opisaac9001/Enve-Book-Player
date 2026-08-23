package com.enve.app.data.remote.dto

import com.enve.app.data.remote.dto.grimmoryapp.LanguageOptionDto
import com.enve.app.data.remote.dto.grimmoryapp.NamedCountDto
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

object FlexibleIdSerializer : KSerializer<String> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("FlexibleId", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: String) = encoder.encodeString(value)

    override fun deserialize(decoder: Decoder): String {
        val jsonDecoder = decoder as? JsonDecoder ?: return decoder.decodeString()
        return when (val element = jsonDecoder.decodeJsonElement()) {
            is JsonPrimitive -> element.contentOrNull
                ?: element.longOrNull?.toString()
                ?: ""
            else -> ""
        }
    }
}

@Serializable
data class LoginRequest(
    val username: String,
    val password: String,
)

@Serializable
data class AuthResponse(
    val accessToken: String,
    val refreshToken: String? = null,
)

@Serializable
data class RefreshRequest(
    val refreshToken: String,
)

@Serializable
data class UserResponse(
    val id: String? = null,
    val username: String? = null,
    val email: String? = null,
)

@Serializable
data class JellyfinAuthRequest(
    @SerialName("Username") val username: String,
    @SerialName("Pw") val password: String,
)

@Serializable
data class JellyfinAuthResponse(
    @SerialName("AccessToken") val accessToken: String? = null,
)

@Serializable
data class PlexAuthResponse(
    val user: PlexUser? = null,
)

@Serializable
data class PlexUser(
    val id: String? = null,
    val username: String? = null,
    val authenticationToken: String? = null,
)

@Serializable
data class LibraryDto(
    @Serializable(with = FlexibleIdSerializer::class) val id: String,
    val name: String,
    val bookCount: Int? = null,
    val allowedFormats: List<String>? = null,
)

@Serializable
data class BookSummaryDto(
    @Serializable(with = FlexibleIdSerializer::class) val id: String,
    val title: String,
    val authors: List<String>? = null,
    val thumbnailUrl: String? = null,
    val readStatus: String? = null,
    val personalRating: Float? = null,
    val seriesName: String? = null,
    val seriesNumber: String? = null,
    @Serializable(with = FlexibleIdSerializer::class) val libraryId: String? = null,

    val libraryName: String? = null,
    val addedOn: String? = null,
    val lastReadTime: String? = null,
    val readProgress: Float? = null,
    val primaryFileType: String? = null,
    val primaryFileName: String? = null,
    val coverUpdatedOn: String? = null,
    val audiobookCoverUpdatedOn: String? = null,
    val dateFinished: String? = null,
    val isPhysical: Boolean? = null,

    val publishedDate: String? = null,
    val goodreadsRating: Float? = null,
    val pageCount: Int? = null,
    val publisher: String? = null,
    val categories: List<String>? = null,
    val language: String? = null,
    val narrator: String? = null,
    val isbn13: String? = null,
    val isbn10: String? = null,
    val ageRating: Int? = null,
    val contentRating: String? = null,
    val fileSizeKb: Long? = null,
    val metadataMatchScore: Float? = null,

    val duration: Double? = null,

    val durationMs: Double? = null,
    val durationSeconds: Long? = null,
    val primaryFile: BookFileDto? = null,
    val fileTypes: List<String>? = null,
    val files: List<BookFileDto>? = null,
    val alternativeFormats: List<BookFileDto>? = null,

    val epubProgress: EbookProgressObjectDto? = null,
)

@Serializable
data class BookDetailDto(
    @Serializable(with = FlexibleIdSerializer::class) val id: String,
    val title: String,
    val subtitle: String? = null,
    val authors: List<String>? = null,
    val description: String? = null,
    val categories: List<String>? = null,
    val publisher: String? = null,
    val publishedDate: String? = null,
    val pageCount: Int? = null,
    val isbn13: String? = null,
    val language: String? = null,
    val goodreadsRating: Float? = null,
    val goodreadsReviewCount: Int? = null,
    val libraryId: String? = null,
    val libraryName: String? = null,
    val thumbnailUrl: String? = null,
    val readStatus: String? = null,
    val personalRating: Float? = null,
    val seriesName: String? = null,
    val seriesNumber: String? = null,
    val addedOn: String? = null,
    val lastReadTime: String? = null,
    val dateFinished: String? = null,
    val readProgress: Float? = null,
    val primaryFileType: String? = null,
    val shelves: List<ShelfDto>? = null,
    val fileTypes: List<String>? = null,
    val files: List<BookFileDto>? = null,
    val primaryFile: BookFileDto? = null,
    val duration: Double? = null,
    val durationSeconds: Long? = null,

    val durationMs: Double? = null,
    val audiobookProgress: AudiobookProgressDto? = null,
    val epubProgress: EbookProgressObjectDto? = null,
    val pdfProgress: PageProgressDto? = null,
    val cbxProgress: PageProgressDto? = null,
    val coverUpdatedOn: String? = null,
    val audiobookCoverUpdatedOn: String? = null,
)

@Serializable
data class BookFileDto(
    @Serializable(with = FlexibleIdSerializer::class) val id: String? = null,
    val fileName: String? = null,
    val filePath: String? = null,
    val fileSubPath: String? = null,
    val bookType: String? = null,
    @SerialName("extension") val fileExtension: String? = null,
    val isPrimary: Boolean? = null,
    val primary: Boolean? = null,
)

@Serializable
data class AudiobookProgressDto(
    val positionMs: Long? = null,
    val trackIndex: Int? = null,
    val percentage: Float? = null,
    val updatedAt: String? = null,
)

@Serializable
data class EbookProgressObjectDto(
    val percentage: Float? = null,
    val cfi: String? = null,
    val href: String? = null,
    val updatedAt: String? = null,
)

@Serializable
data class PageProgressDto(
    val percentage: Float? = null,
    val page: Int? = null,
    val updatedAt: String? = null,
)

@Serializable
data class LegacyBookloreBookDto(
    @Serializable(with = FlexibleIdSerializer::class) val id: String,
    @Serializable(with = FlexibleIdSerializer::class) val libraryId: String? = null,
    val name: String? = null,
    val title: String? = null,
    val addedOn: String? = null,
    val lastReadTime: String? = null,
    val readProgress: Float? = null,
    val readStatus: String? = null,
    val metadata: LegacyBookloreMetadataDto? = null,
    val primaryFile: BookFileDto? = null,
    val alternativeFormats: List<BookFileDto>? = null,
)

@Serializable
data class LegacyBookloreMetadataDto(
    val title: String? = null,
    val authors: List<String>? = null,
    val seriesName: String? = null,
    val seriesNumber: String? = null,
    val description: String? = null,
    val publisher: String? = null,
    val publishedDate: String? = null,
    val narrator: String? = null,
    val pageCount: Int? = null,
    val isbn13: String? = null,
    val language: String? = null,
    val thumbnailUrl: String? = null,
    val coverUpdatedOn: String? = null,
    val audiobookCoverUpdatedOn: String? = null,
)

@Serializable
data class PaginatedBooksResponse(
    val content: List<BookSummaryDto> = emptyList(),
    val totalElements: Int? = null,
    val totalPages: Int? = null,

    @SerialName("page") val page: Int? = null,
    val size: Int? = null,
    val hasNext: Boolean? = null,
    val hasPrevious: Boolean? = null,
)

@Serializable
data class AudiobookInfoDto(
    val bookId: String,
    val bookFileId: String? = null,
    val title: String? = null,
    val author: String? = null,
    val narrator: String? = null,
    val durationMs: Long? = null,
    val bitrate: Int? = null,
    val codec: String? = null,
    val sampleRate: Int? = null,
    val channels: Int? = null,
    val totalSizeBytes: Long? = null,
    val folderBased: Boolean? = null,
    val chapters: List<ChapterDto>? = null,
    val tracks: List<TrackDto>? = null,
)

@Serializable
data class ChapterDto(
    val index: Int,
    val title: String? = null,
    val startTimeMs: Long,
    val endTimeMs: Long,
    val durationMs: Long? = null,
)

@Serializable
data class TrackDto(
    val index: Int,
    val fileName: String? = null,
    val title: String? = null,
    val durationMs: Long? = null,
    val fileSizeBytes: Long? = null,
    val cumulativeStartMs: Long? = null,
)

@Serializable
data class ShelfDto(
    val id: String,
    val name: String,
    val bookCount: Int? = null,
)

@Serializable
data class GrimmoryAppBookProgressDto(
    val readProgress: Float? = null,
    val readStatus: String? = null,
    val epubProgress: EbookProgressObjectDto? = null,
    val pdfProgress: PageProgressDto? = null,
    val audiobookProgress: AudiobookProgressDto? = null,
    val koreaderProgress: GrimmoryKoreaderProgressDto? = null,
)

@Serializable
data class GrimmoryKoreaderProgressDto(
    val percentage: Float? = null,
    val device: String? = null,
    val deviceId: String? = null,
)

@Serializable
data class GrimmoryUpdateProgressRequest(
    val fileProgress: GrimmoryFileProgressDto? = null,
)

@Serializable
data class GrimmoryFileProgressDto(
    val bookFileId: Long,
    val positionData: String? = null,
    val positionHref: String? = null,
    val progressPercent: Double,
    val ttsPositionCfi: String? = null,
    val contentSourceProgressPercent: Double? = null,
)

@Serializable
data class GrimmoryProgressRequest(
    val bookId: Long,
    val fileProgress: GrimmoryProgressFileProgress,
    val dateFinished: String? = null,
)

@Serializable
data class GrimmoryProgressFileProgress(
    val bookFileId: Long,
    val positionData: String? = null,
    val positionHref: String? = null,
    val progressPercent: Double,
)

@Serializable
data class PublicSettingsDto(
    val oidcEnabled: Boolean? = null,
    val oidcProviderName: String? = null,
    val oidcProviderDetails: OidcProviderDetailsDto? = null,
    val serverName: String? = null,
)

@Serializable
data class OidcProviderDetailsDto(
    val issuerUri: String? = null,
    val clientId: String? = null,
    val scopes: String? = null,
)

@Serializable
data class OidcStateDto(
    val state: String? = null,
    val nonce: String? = null,
    val authorizationUrl: String? = null,
)

@Serializable
data class OidcCallbackRequest(
    val code: String,
    val state: String,

    val codeVerifier: String? = null,
    val redirectUri: String? = null,
    val nonce: String? = null,
)

@Serializable
data class OidcDiscoveryDto(
    @kotlinx.serialization.SerialName("authorization_endpoint")
    val authorizationEndpoint: String? = null,
)

@Serializable
data class SeriesSummaryDto(
    @SerialName("seriesName") val name: String,
    val bookCount: Int? = null,
    val bookIds: List<String>? = null,

    val id: String? = null,
    val coverUrl: String? = null,
)

@Serializable
data class PaginatedSeriesResponse(
    val content: List<SeriesSummaryDto> = emptyList(),
    val totalElements: Int? = null,
    val totalPages: Int? = null,
    val number: Int? = null,
    val hasNext: Boolean? = null,
)

@Serializable
data class FilterOptionsDto(
    val authors: List<NamedCountDto>? = null,
    val narrators: List<NamedCountDto>? = null,
    val languages: List<LanguageOptionDto>? = null,
    val categories: List<NamedCountDto>? = null,
    val fileTypes: List<NamedCountDto>? = null,
    val publishers: List<NamedCountDto>? = null,
)

@Serializable
data class UpdateStatusRequest(
    val status: String,
)

@Serializable
data class UpdateRatingRequest(
    val ids: List<Long>,
    val rating: Int,
)

@Serializable
data class MagicShelfDto(
    val id: String,
    val name: String,
    val description: String? = null,
    val bookCount: Int? = null,
    val isPublic: Boolean? = null,
)

@Serializable
data class AuthorSummaryDto(
    val id: String,
    val name: String,
    val photoUrl: String? = null,
    val bookCount: Int? = null,
)

@Serializable
data class AuthorDetailDto(
    val id: String,
    val name: String,
    val photoUrl: String? = null,
    val biography: String? = null,
    val books: List<BookSummaryDto>? = null,
)

@Serializable
data class PaginatedAuthorsResponse(
    val content: List<AuthorSummaryDto> = emptyList(),
    val totalElements: Int? = null,
    val totalPages: Int? = null,
    val number: Int? = null,
    val hasNext: Boolean? = null,
)

@Serializable
data class NotebookBookSummaryDto(
    @Serializable(with = FlexibleIdSerializer::class) val bookId: String,
    val bookTitle: String? = null,
    val noteCount: Int? = null,
    val authors: List<String>? = null,
    val coverUpdatedOn: String? = null,
)

@Serializable
data class NotebookEntryDto(
    @Serializable(with = FlexibleIdSerializer::class) val id: String,
    val type: String? = null,
    val text: String? = null,
    val note: String? = null,
    val style: String? = null,
    val chapterTitle: String? = null,
    val color: String? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

@Serializable
data class PaginatedNotebookBooksResponse(
    val content: List<NotebookBookSummaryDto> = emptyList(),
    val totalElements: Int? = null,
    val totalPages: Int? = null,
    val number: Int? = null,
    val hasNext: Boolean? = null,
)

@Serializable
data class PaginatedNotebookEntriesResponse(
    val content: List<NotebookEntryDto> = emptyList(),
    val totalElements: Int? = null,
    val totalPages: Int? = null,
    val number: Int? = null,
    val hasNext: Boolean? = null,
)

@Serializable
data class ReadingStreakDto(
    val currentStreak: Int? = null,
    val longestStreak: Int? = null,
    val totalReadingDays: Int? = null,
    val last52Weeks: List<GrimmoryStreakDayDto> = emptyList(),
)

@Serializable
data class GrimmoryStreakDayDto(val date: String, val active: Boolean)

@Serializable
data class GrimmoryActivityDayDto(val date: String, val count: Int)

@Serializable
data class GrimmoryPeakHourDto(val hourOfDay: Int, val sessionCount: Int, val totalDurationSeconds: Long)

@Serializable
data class GrimmoryFavoriteDayDto(
    val dayOfWeek: Int,
    val dayName: String,
    val sessionCount: Int,
    val totalDurationSeconds: Long,
)

@Serializable
data class GrimmoryGenreStatDto(
    val genre: String,
    val bookCount: Int,
    val totalSessions: Int,
    val totalDurationSeconds: Long,
    val averageSessionsPerBook: Double,
)

@Serializable
data class GrimmoryCompletionMonthDto(
    val year: Int,
    val month: Int,
    val totalBooks: Int,
    val statusBreakdown: Map<String, Int> = emptyMap(),
    val finishedBooks: Int,
    val completionRate: Double,
)

@Serializable
data class GrimmoryCompletionHeatmapMonthDto(val year: Int, val month: Int, val count: Int)

@Serializable
data class GrimmoryPageTurnerDto(
    val bookId: Long,
    val bookTitle: String,
    val categories: List<String> = emptyList(),
    val pageCount: Int? = null,
    val personalRating: Int? = null,
    val gripScore: Int,
    val totalSessions: Int,
    val avgSessionDurationSeconds: Double,
    val sessionAcceleration: Double,
    val gapReduction: Double,
    val finishBurst: Boolean,
)

@Serializable
data class GrimmoryBookDistributionsDto(
    val ratingDistribution: List<GrimmoryRatingBucketDto> = emptyList(),
    val progressDistribution: List<GrimmoryProgressBucketDto> = emptyList(),
    val statusDistribution: List<GrimmoryStatusBucketDto> = emptyList(),
)

@Serializable
data class GrimmoryRatingBucketDto(val rating: Int, val count: Int)

@Serializable
data class GrimmoryProgressBucketDto(val range: String, val min: Int, val max: Int, val count: Int)

@Serializable
data class GrimmoryStatusBucketDto(val status: String, val count: Int)

@Serializable
data class GrimmoryReadingSpeedDayDto(val date: String, val avgProgressPerMinute: Double, val totalSessions: Int)

@Serializable
data class GrimmorySessionPointDto(val hourOfDay: Double, val durationMinutes: Double, val dayOfWeek: Int)

@Serializable
data class GrimmoryBookTimelineEntryDto(
    val bookId: Long,
    val title: String,
    val pageCount: Int? = null,
    val firstSessionDate: String,
    val lastSessionDate: String,
    val totalSessions: Int,
    val totalDurationSeconds: Long,
    val maxProgress: Double,
    val readStatus: String? = null,
)

@Serializable
data class GrimmoryCompletionRacePointDto(
    val bookId: Long,
    val bookTitle: String,
    val sessionDate: String,
    val endProgress: Double,
)

@Serializable
data class GrimmoryListeningWeekDto(val year: Int, val week: Int, val totalDurationSeconds: Long, val sessions: Int)

@Serializable
data class GrimmoryListeningMonthDto(
    val year: Int,
    val month: Int,
    val booksCompleted: Int,
    val totalListeningSeconds: Long,
)

@Serializable
data class GrimmoryListeningFunnelDto(
    val totalStarted: Int,
    val reached25: Int,
    val reached50: Int,
    val reached75: Int,
    val completed: Int,
)

@Serializable
data class GrimmoryAuthorStatDto(
    val author: String,
    val bookCount: Int,
    val totalSessions: Int,
    val totalDurationSeconds: Long,
)

@Serializable
data class GrimmoryLongestAudiobookDto(
    val bookId: Long,
    val title: String,
    val totalDurationSeconds: Long,
    val listenedDurationSeconds: Long,
    val progressPercent: Double,
)

@Serializable
data class ListeningCompletionDto(
    val totalAudiobooks: Int? = null,
    val completed: Int? = null,
    val inProgressCount: Int? = null,
    val inProgress: List<GrimmoryAudiobookProgressDto> = emptyList(),
)

@Serializable
data class GrimmoryAudiobookProgressDto(
    val bookId: Long,
    val title: String,
    val progressPercent: Double,
    val totalDurationSeconds: Long,
    val listenedDurationSeconds: Long,
)

@Serializable
data class ReadingSessionResponseDto(
    @Serializable(with = FlexibleIdSerializer::class) val id: String? = null,
    @Serializable(with = FlexibleIdSerializer::class) val bookId: String? = null,
    val startTime: String? = null,
    val endTime: String? = null,
    val durationSeconds: Int? = null,
    val startProgress: Float? = null,
    val endProgress: Float? = null,
)

@Serializable
data class PaginatedReadingSessionsResponse(
    val content: List<ReadingSessionResponseDto> = emptyList(),
    val totalElements: Int? = null,
    val totalPages: Int? = null,
    val number: Int? = null,
)

@Serializable
data class GrimmoryBookmarkDto(
    @Serializable(with = FlexibleIdSerializer::class) val id: String,
    @Serializable(with = FlexibleIdSerializer::class) val bookId: String? = null,
    val cfi: String? = null,
    val positionMs: Double? = null,
    val trackIndex: Int? = null,
    val title: String? = null,
    val notes: String? = null,
    val color: String? = null,
    val priority: Int? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

@Serializable
data class GrimmoryBookmarkCreateRequest(
    val bookId: Int,
    val title: String? = null,
    val notes: String? = null,
    val cfi: String? = null,
    val color: String? = null,
    val priority: Int? = null,
    val positionMs: Int? = null,
    val trackIndex: Int? = null,
)

@Serializable
data class GrimmoryBookmarkUpdateRequest(
    val title: String? = null,
    val cfi: String? = null,
    val color: String? = null,
    val notes: String? = null,
    val priority: Int? = null,
)

@Serializable
data class GrimmoryAnnotationDto(
    val id: Long,
    val bookId: Long,
    val cfi: String? = null,
    val text: String? = null,
    val color: String? = null,
    val style: String? = null,
    val note: String? = null,
    val chapterTitle: String? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

@Serializable
data class GrimmoryAnnotationCreateRequest(
    val bookId: Long,
    val cfi: String,
    val text: String,
    val color: String,
    val style: String,
    val note: String? = null,
    val chapterTitle: String? = null,
)

@Serializable
data class GrimmoryAnnotationUpdateRequest(
    val color: String,
    val style: String,
    val note: String? = null,
)

@Serializable
data class GrimmoryBookNoteDto(
    val id: Long,
    val bookId: Long,
    val cfi: String? = null,
    val selectedText: String? = null,
    val noteContent: String? = null,
    val color: String? = null,
    val chapterTitle: String? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

@Serializable
data class GrimmoryBookNoteCreateRequest(
    val bookId: Long,
    val cfi: String,
    val selectedText: String,
    val noteContent: String,
    val color: String,
    val chapterTitle: String? = null,
)

@Serializable
data class GrimmoryBookNoteUpdateRequest(
    val noteContent: String,
    val color: String,
    val chapterTitle: String? = null,
)

@Serializable
data class UserStatsDto(
    val totalListeningTimeMs: Long? = null,
    val totalReadingTimeMs: Long? = null,
    val weeklyActivityTimeMs: Long? = null,
    val booksFinished: Int? = null,
    val booksInProgress: Int? = null,
    val sessionsCount: Int? = null,
    val currentStreak: Int? = null,
    val longestStreak: Int? = null,
    val averageDailyMs: Long? = null,
    val totalReadingDays: Int? = null,
)

@Serializable
data class ReadingSessionRequest(
    val bookId: Long,
    val bookType: String,
    val startTime: String,
    val endTime: String,
    val durationSeconds: Int,
    val durationFormatted: String,
    val startProgress: Float? = null,
    val endProgress: Float? = null,
    val progressDelta: Float? = null,
    val startLocation: String? = null,
    val endLocation: String? = null,
)

@Serializable
data class GrimmoryRecommendationDto(
    val book: GrimmoryRecommendedBookDto? = null,
    val similarityScore: Double = 0.0,
)

@Serializable
data class GrimmoryRecommendedBookDto(
    @Serializable(with = FlexibleIdSerializer::class) val id: String,
)
