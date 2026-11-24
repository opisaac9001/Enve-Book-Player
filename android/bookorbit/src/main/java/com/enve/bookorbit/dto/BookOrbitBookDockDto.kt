package com.enve.bookorbit.dto

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

@Serializable
data class BookOrbitBookDockMetadataDto(
    val title: String? = null,
    val subtitle: String? = null,
    val authors: List<String> = emptyList(),
    val narrators: List<String> = emptyList(),
    val description: String? = null,
    val publisher: String? = null,
    val publishedYear: Int? = null,
    val language: String? = null,
    val isbn13: String? = null,
    val seriesName: String? = null,
    @Serializable(with = BookOrbitSeriesIndexSerializer::class)
    val seriesIndex: String? = null,
    val genres: List<String> = emptyList(),
)

@Serializable
data class BookOrbitBookDockHoldDetailDto(
    val confidence: Double? = null,
    val threshold: Double? = null,
    val libraryId: Int? = null,
    val libraryName: String? = null,
    val bookId: Int? = null,
    val keepBoth: Boolean? = null,
)

@Serializable
data class BookOrbitBookDockFileDto(
    val id: Int,
    val fileName: String = "",
    val fileSize: Long? = null,
    val format: String? = null,
    val status: String = "",
    val embeddedMetadata: JsonObject? = null,
    val selectedMetadata: JsonObject? = null,
    val fetchedMetadata: JsonObject? = null,
    val targetLibraryId: Int? = null,
    val targetFolderId: Int? = null,
    val confidence: Double? = null,
    val errorMessage: String? = null,
    val metadataEditedAt: String? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
    val dockId: Int? = null,
    val holdReason: String? = null,
    val holdDetail: BookOrbitBookDockHoldDetailDto? = null,
    val formerLibraryName: String? = null,
    val alsoIn: List<String> = emptyList(),
)

@Serializable
data class BookOrbitBookDockFilesPageDto(
    val items: List<BookOrbitBookDockFileDto> = emptyList(),
    val total: Int = 0,
    val page: Int = 1,
    val size: Int = 20,
)

@Serializable
data class BookOrbitBookDockSummaryDto(
    val pending: Int = 0,
    val working: Int = 0,
    val ready: Int = 0,
    val error: Int = 0,
    val needsReview: Int = 0,
    val readyToFile: Int = 0,
    val total: Int = 0,
    val paused: Boolean = false,
)

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class BookOrbitBookDockUpdateRequest(
    @EncodeDefault(EncodeDefault.Mode.NEVER) val selectedMetadata: JsonObject? = null,
    @EncodeDefault(EncodeDefault.Mode.NEVER) val targetLibraryId: Int? = null,
    @EncodeDefault(EncodeDefault.Mode.NEVER) val targetFolderId: Int? = null,
)

@Serializable
data class BookOrbitBookDockSelectionRequest(
    val fileIds: List<Int>,
)

@Serializable
data class BookOrbitBookDockApplyFetchedDto(
    val total: Int = 0,
    val applied: Int = 0,
    val skipped: Int = 0,
    val skippedEdited: Int = 0,
)

@Serializable
data class BookOrbitBookDockFinalizeFileDto(
    val fileId: Int,
    val fileName: String = "",
    val newName: String? = null,
    val success: Boolean = false,
    val bookId: Int? = null,
    val isDuplicate: Boolean = false,
    val existingBookId: Int? = null,
    val message: String? = null,
    val errorCode: String? = null,
)

@Serializable
data class BookOrbitBookDockFinalizeDto(
    val total: Int = 0,
    val succeeded: Int = 0,
    val failed: Int = 0,
    val results: List<BookOrbitBookDockFinalizeFileDto> = emptyList(),
)

@Serializable
data class BookOrbitLibraryFolderDto(
    val id: Int,
    val path: String = "",
)

@Serializable
data class BookOrbitErrorDto(
    val message: JsonElement? = null,
)
