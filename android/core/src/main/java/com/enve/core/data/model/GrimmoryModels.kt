package com.enve.core.data.model

import kotlinx.serialization.Serializable

@Serializable
data class BookSummary(
    val id: String,
    val connectionId: String,
    val source: BookSource = BookSource.GRIMMORY,
    val title: String,
    val authors: List<String> = emptyList(),
    val thumbnailUrl: String? = null,
    val seriesName: String? = null,
    val seriesNumber: String? = null,
    val readProgress: Float = 0f,
    val readStatus: ReadStatus = ReadStatus.UNREAD,
    val personalRating: Float? = null,
    val primaryFileType: String? = null,
    val mediaType: AppMediaType = AppMediaType.AUDIOBOOK,
    val addedOn: Long = 0L,
    val lastReadTime: Long = 0L,
    val isPhysical: Boolean = false,
    val libraryId: String? = null,
    val hideFromContinue: Boolean = false,
    val serverReadStatus: String? = null,
    val hasAudio: Boolean = false,
    val hasEbook: Boolean = false,
    val publishedDate: String? = null,
    val goodreadsRating: Float? = null,
    val narrator: String? = null,
    val publisher: String? = null,
    val categories: List<String> = emptyList(),
    val language: String? = null,
    val isbn13: String? = null,
    val pageCount: Int? = null,
) {
    val uniqueKey: String get() = "$connectionId:$id"
}

@Serializable
data class BrowseGroup(
    val key: String,
    val name: String,
    val count: Int,
    val coverUrl: String? = null,
    val secondary: String? = null,
    val sourceConnectionId: String? = null,
    val source: BookSource = BookSource.GRIMMORY,
    val description: String? = null,
    val icon: String? = null,
    val isEditable: Boolean = false,
    val syncToKobo: Boolean = false,
    val displayOrder: Int = 0,
)

@Serializable
data class BookSummaryPage(
    val items: List<BookSummary>,
    val page: Int,
    val totalPages: Int,
    val totalElements: Long,
    val hasNext: Boolean,
)

@Serializable
data class GrimmoryGroupPage(
    val items: List<BrowseGroup>,
    val page: Int,
    val totalPages: Int,
    val totalElements: Long,
    val hasNext: Boolean,
)

@Serializable
data class GrimmoryLibrary(
    val id: Long,
    val name: String,
    val bookCount: Int = 0,
    val allowedFormats: List<String> = emptyList(),
    val paths: List<String> = emptyList(),
)

@Serializable
data class GrimmoryShelf(
    val id: Long,
    val name: String,
    val icon: String? = null,
    val bookCount: Int = 0,
    val publicShelf: Boolean = false,
)

@Serializable
data class GrimmoryMagicShelf(
    val id: Long,
    val name: String,
    val icon: String? = null,
    val iconType: String? = null,
    val publicShelf: Boolean = false,
)

@Serializable
data class GrimmoryFilterOptions(
    val authors: List<NamedCount> = emptyList(),
    val narrators: List<NamedCount> = emptyList(),
    val categories: List<NamedCount> = emptyList(),
    val languages: List<LanguageOption> = emptyList(),
    val readStatuses: List<NamedCount> = emptyList(),
    val fileTypes: List<NamedCount> = emptyList(),
    val publishers: List<NamedCount> = emptyList(),
)

@Serializable
data class NamedCount(val name: String, val count: Int = 0)

@Serializable
data class LanguageOption(val code: String, val label: String, val count: Int = 0)

@Serializable
data class GrimmoryUser(
    val isAdmin: Boolean = false,
    val canUpload: Boolean = false,
    val canDownload: Boolean = false,
    val canAccessBookdrop: Boolean = false,
    val maxFileUploadSizeMb: Int? = null,
)

@Serializable
data class GrimmoryAuthorDetail(
    val id: String,
    val name: String,
    val description: String? = null,
    val asin: String? = null,
    val bookCount: Int = 0,
    val hasPhoto: Boolean = false,
)

fun BookSummary.toShallowBook(isDownloaded: Boolean = false): Book = Book(
    id = id,
    title = title,
    author = authors.joinToString(", ").takeIf { it.isNotBlank() },
    narrator = narrator,
    coverUrl = thumbnailUrl,
    source = source,
    mediaType = mediaType,
    readStatus = readStatus,
    seriesName = seriesName,
    seriesNumber = seriesNumber,
    primaryFileType = primaryFileType,
    libraryId = libraryId?.let { "$connectionId::$it" },
    connectionId = connectionId,
    addedOn = addedOn,
    lastReadTime = lastReadTime,
    readProgress = readProgress.coerceIn(0f, 1f),
    isFinished = readStatus == ReadStatus.COMPLETED,
    hideFromContinue = hideFromContinue,
    serverReadStatus = serverReadStatus,
    personalRating = personalRating,
    publishedDate = publishedDate,
    goodreadsRating = goodreadsRating,
    publisher = publisher,
    categories = categories,
    language = language,
    isbn13 = isbn13,
    pageCount = pageCount,
    isDownloaded = isDownloaded,
    hasAudio = hasAudio || mediaType == AppMediaType.AUDIOBOOK,
    hasEbook = hasEbook || mediaType == AppMediaType.EBOOK,
)

fun GrimmoryLibrary.toLegacyLibrary(connectionId: String): Library = Library(
    id = "$connectionId::$id",
    name = name,
    bookCount = bookCount,
    source = BookSource.GRIMMORY,
    connectionId = connectionId,
)
