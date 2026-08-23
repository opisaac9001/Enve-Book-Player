package com.enve.komga.dto

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
data class KomgaLibraryDto(
    val id: String,
    val name: String,
    val root: String? = null,
    val unavailable: Boolean? = null,
)

@Serializable
data class KomgaPage<T>(
    val content: List<T> = emptyList(),
    val empty: Boolean? = null,
    val first: Boolean? = null,
    val last: Boolean? = null,
    val number: Int? = null,
    val numberOfElements: Int? = null,
    val pageable: JsonElement? = null,
    val size: Int? = null,
    val sort: JsonElement? = null,
    val totalElements: Int? = null,
    val totalPages: Int? = null,
)

@Serializable
data class KomgaBookDto(
    val id: String,
    val seriesId: String,
    val seriesTitle: String,
    val libraryId: String,
    val name: String,
    val number: Int? = null,
    val created: String? = null,
    val lastModified: String? = null,
    val fileLastModified: String? = null,
    val sizeBytes: Long? = null,
    val size: String? = null,
    val media: KomgaMediaDto? = null,
    val metadata: KomgaBookMetadataDto? = null,
    val readProgress: KomgaReadProgressDto? = null,
    val deleted: Boolean? = null,
    val fileHash: String? = null,
    val oneshot: Boolean? = null,
)

internal data class KomgaBookDisplayMetadata(
    val title: String,
    val seriesName: String?,
    val seriesNumber: String?,
)

internal fun KomgaBookDto.displayMetadata(): KomgaBookDisplayMetadata {
    val seriesName = seriesTitle.trim().takeIf { it.isNotEmpty() }
    val seriesNumber = metadata?.number?.trim()?.takeIf { it.isNotEmpty() } ?: number?.toString()
    val bookTitle = metadata?.title?.trim()?.takeIf { it.isNotEmpty() } ?: name
    val title = if (seriesName != null && seriesNumber != null && bookTitle.isIssueNumberOnly(seriesNumber)) {
        "$seriesName - $seriesNumber"
    } else {
        bookTitle
    }
    return KomgaBookDisplayMetadata(title, seriesName, seriesNumber)
}

private fun String.isIssueNumberOnly(issueNumber: String): Boolean =
    trim().trimStart('#').equals(issueNumber.trim().trimStart('#'), ignoreCase = true)

@Serializable
data class KomgaMediaDto(
    val status: String? = null,
    val mediaType: String? = null,
    val pagesCount: Int? = null,
    val comment: String? = null,
)

@Serializable
data class KomgaBookMetadataDto(
    val title: String? = null,
    val titleLock: Boolean? = null,
    val summary: String? = null,
    val summaryLock: Boolean? = null,
    val number: String? = null,
    val numberLock: Boolean? = null,
    val numberSort: Float? = null,
    val numberSortLock: Boolean? = null,
    val releaseDate: String? = null,
    val releaseDateLock: Boolean? = null,
    val authors: List<KomgaAuthorDto>? = null,
    val authorsLock: Boolean? = null,
    val tags: List<String>? = null,
    val tagsLock: Boolean? = null,
    val isbn: String? = null,
    val isbnLock: Boolean? = null,
    val links: List<KomgaWebLinkDto>? = null,
    val linksLock: Boolean? = null,
    val created: String? = null,
    val lastModified: String? = null,
)

@Serializable
data class KomgaSeriesDto(
    val id: String,
    val libraryId: String,
    val name: String,
    val created: String? = null,
    val lastModified: String? = null,
    val booksCount: Int? = null,
    val metadata: KomgaSeriesMetadataDto? = null,
)

@Serializable
data class KomgaSeriesMetadataDto(

    val readingDirection: String? = null,
)

@Serializable
data class KomgaAuthorDto(
    val name: String,
    val role: String,
)

@Serializable
data class KomgaWebLinkDto(
    val label: String,
    val url: String,
)

@Serializable
data class KomgaReadProgressDto(
    val page: Int,
    val completed: Boolean,
    val readDate: String? = null,
    val created: String? = null,
    val lastModified: String? = null,
)

@Serializable
data class KomgaReadProgressUpdateDto(
    val page: Int? = null,
    val completed: Boolean? = null,
)

@Serializable
data class KomgaReadListDto(
    val id: String,
    val name: String,
    val bookIds: List<String>? = null,
)

@Serializable
data class KomgaCollectionDto(
    val id: String,
    val name: String,
    val seriesIds: List<String>? = null,
)

@Serializable
data class KomgaUserDto(
    val id: String,
    val email: String,
    val roles: List<String> = emptyList(),
    val sharedAllLibraries: Boolean? = null,
    val sharedLibrariesIds: List<String> = emptyList(),
    val labelsAllow: List<String> = emptyList(),
    val labelsExclude: List<String> = emptyList(),
    val ageRestriction: KomgaAgeRestrictionDto? = null,
)

@Serializable
data class KomgaAgeRestrictionDto(
    val age: Int,
    val restriction: String,
)

@Serializable
data class KomgaUserCreationDto(
    val email: String,
    val password: String,
    val roles: List<String> = emptyList(),
)

@Serializable
data class KomgaUserUpdateDto(
    val email: String? = null,
    val roles: List<String>? = null,
    val sharedLibraries: KomgaSharedLibrariesUpdateDto? = null,
    val ageRestriction: KomgaAgeRestrictionUpdateDto? = null,
    val labelsAllow: List<String>? = null,
    val labelsExclude: List<String>? = null,
)

@Serializable
data class KomgaSharedLibrariesUpdateDto(
    val all: Boolean,
    val libraryIds: List<String> = emptyList(),
)

@Serializable
data class KomgaAgeRestrictionUpdateDto(
    val age: Int? = null,
    val restriction: String? = null,
)

@Serializable
data class KomgaPasswordUpdateDto(
    val password: String,
)

@Serializable
data class KomgaLibraryCreationDto(
    val name: String,
    val root: String,
    val importComicInfoBook: Boolean = true,
    val importComicInfoSeries: Boolean = true,
    val importComicInfoCollection: Boolean = true,
    val importComicInfoReadList: Boolean = true,
    val importEpubBook: Boolean = true,
    val importEpubSeries: Boolean = true,
    val importLocalArtwork: Boolean = true,
    val importBarcodeIsbn: Boolean = true,
    val scanForceModifiedTime: Boolean = false,
    val scanInterval: String = "EVERY_6H",
    val scanOnStartup: Boolean = false,
    val scanCbx: Boolean = true,
    val scanPdf: Boolean = true,
    val scanEpub: Boolean = true,
    val analyzeDimensions: Boolean = true,
    val emptyTrashAfterScan: Boolean = false,
    val seriesCover: String = "FIRST",
    val hashFiles: Boolean = true,
    val hashPages: Boolean = false,
    val hashKoreader: Boolean = false,
    val convertToCbz: Boolean = false,
    val unavailableDate: String? = null,
)

@Serializable
data class KomgaLibraryUpdateDto(
    val name: String? = null,
    val root: String? = null,
    val importComicInfoBook: Boolean? = null,
    val importComicInfoSeries: Boolean? = null,
    val importComicInfoCollection: Boolean? = null,
    val importComicInfoReadList: Boolean? = null,
    val importEpubBook: Boolean? = null,
    val importEpubSeries: Boolean? = null,
    val importLocalArtwork: Boolean? = null,
    val importBarcodeIsbn: Boolean? = null,
    val scanForceModifiedTime: Boolean? = null,
    val scanInterval: String? = null,
    val scanOnStartup: Boolean? = null,
    val scanCbx: Boolean? = null,
    val scanPdf: Boolean? = null,
    val scanEpub: Boolean? = null,
    val analyzeDimensions: Boolean? = null,
    val emptyTrashAfterScan: Boolean? = null,
    val seriesCover: String? = null,
    val hashFiles: Boolean? = null,
    val hashPages: Boolean? = null,
    val hashKoreader: Boolean? = null,
    val convertToCbz: Boolean? = null,
)

@Serializable
data class KomgaCollectionCreationDto(
    val name: String,
    val ordered: Boolean = false,
    val seriesIds: List<String> = emptyList(),
)

@Serializable
data class KomgaCollectionUpdateDto(
    val name: String? = null,
    val ordered: Boolean? = null,
    val seriesIds: List<String>? = null,
)

@Serializable
data class KomgaReadListCreationDto(
    val name: String,
    val summary: String? = null,
    val ordered: Boolean = true,
    val bookIds: List<String> = emptyList(),
)

@Serializable
data class KomgaReadListUpdateDto(
    val name: String? = null,
    val summary: String? = null,
    val ordered: Boolean? = null,
    val bookIds: List<String>? = null,
)

@Serializable
data class KomgaActuatorInfoDto(
    val build: KomgaActuatorBuildDto? = null,
    val app: kotlinx.serialization.json.JsonElement? = null,
    val java: kotlinx.serialization.json.JsonElement? = null,
    val os: kotlinx.serialization.json.JsonElement? = null,
)

@Serializable
data class KomgaActuatorBuildDto(
    val artifact: String? = null,
    val name: String? = null,
    val version: String? = null,
    val time: String? = null,
)

@Serializable
data class KomgaTaskDto(
    val type: String? = null,
    val priority: Int? = null,
    val groupId: String? = null,
    val ownerId: String? = null,
    val createdAt: String? = null,

    val description: String? = null,
)

@Serializable
data class KomgaAnnouncementsDto(
    val version: Int? = null,
    val feed: KomgaAnnouncementFeedDto? = null,
)

@Serializable
data class KomgaAnnouncementFeedDto(
    val title: String? = null,
    val items: List<KomgaAnnouncementItemDto> = emptyList(),
)

@Serializable
data class KomgaAnnouncementItemDto(
    val id: String,
    val title: String? = null,
    val date_published: String? = null,
    val content_html: String? = null,
    val url: String? = null,
    val read: Boolean? = null,
)

@Serializable
data class KomgaHistoryEventDto(
    val type: String? = null,
    val timestamp: String? = null,
    val bookId: String? = null,
    val seriesId: String? = null,
    val libraryId: String? = null,
    val properties: Map<String, String> = emptyMap(),
)

@Serializable
data class KomgaApiKeyDto(
    val id: String,
    val userId: String? = null,
    val key: String? = null,
    val comment: String? = null,
    val createdDate: String? = null,
    val lastModifiedDate: String? = null,
)

@Serializable
data class KomgaApiKeyCreationDto(
    val comment: String,
)
