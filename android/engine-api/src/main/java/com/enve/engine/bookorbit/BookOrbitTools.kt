package com.enve.engine.bookorbit

import com.enve.core.data.model.Book

enum class BookOrbitFailureReason { UNAUTHORIZED, FORBIDDEN, UNSUPPORTED, REJECTED, UNREACHABLE }

class BookOrbitToolException(
    val reason: BookOrbitFailureReason,
    val serverMessage: String? = null,
) : Exception(serverMessage ?: reason.name)

data class BookOrbitSmartScope(
    val id: Int,
    val name: String,
    val bookCount: Int?,
    val shared: Boolean,
)

data class BookOrbitSmartScopePage(
    val books: List<Book>,
    val total: Int,
    val page: Int,
)

data class BookOrbitBookDropAccess(
    val canView: Boolean,
    val canApprove: Boolean,
    val managesAll: Boolean,
)

enum class BookOrbitBookDropStatus(val wire: String?) {
    PENDING("pending"),
    EXTRACTING(null),
    FETCHING(null),
    READY("ready"),
    ERROR("error"),
    UNKNOWN(null),
}

data class BookOrbitBookDropMetadata(
    val title: String = "",
    val subtitle: String = "",
    val authors: List<String> = emptyList(),
    val narrators: List<String> = emptyList(),
    val description: String = "",
    val publisher: String = "",
    val publishedYear: Int? = null,
    val language: String = "",
    val isbn13: String = "",
    val seriesName: String = "",
    val seriesIndex: String = "",
    val genres: List<String> = emptyList(),
)

data class BookOrbitBookDropItem(
    val id: Int,
    val fileName: String,
    val fileSizeBytes: Long?,
    val format: String?,
    val status: BookOrbitBookDropStatus,
    val metadata: BookOrbitBookDropMetadata,
    val embedded: BookOrbitBookDropMetadata?,
    val fetched: BookOrbitBookDropMetadata?,
    val edited: Boolean,
    val targetLibraryId: Int?,
    val targetFolderId: Int?,
    val confidence: Double?,
    val errorMessage: String?,
    val holdReason: String?,
    val holdLibraryName: String?,
    val formerLibraryName: String?,
    val alsoIn: List<String>,
)

data class BookOrbitBookDropPage(
    val items: List<BookOrbitBookDropItem>,
    val total: Int,
    val page: Int,
)

data class BookOrbitBookDropSummary(
    val pending: Int,
    val ready: Int,
    val error: Int,
    val needsReview: Int,
    val total: Int,
    val paused: Boolean,
)

data class BookOrbitBookDropFolder(
    val id: Int,
    val path: String,
)

data class BookOrbitBookDropLibrary(
    val id: Int,
    val name: String,
    val folders: List<BookOrbitBookDropFolder>,
    val allowedFormats: List<String>,
)

data class BookOrbitBookDropQuery(
    val page: Int = 1,
    val status: BookOrbitBookDropStatus? = null,
    val search: String = "",
)

data class BookOrbitBookDropEdit(
    val metadata: BookOrbitBookDropMetadata?,
    val targetLibraryId: Int?,
    val targetFolderId: Int?,
)

data class BookOrbitBookDropApplied(
    val applied: Int,
    val skippedEdited: Int,
    val skipped: Int,
)

data class BookOrbitBookDropFileResult(
    val fileId: Int,
    val fileName: String,
    val success: Boolean,
    val duplicate: Boolean,
    val message: String?,
)

data class BookOrbitBookDropApproval(
    val total: Int,
    val succeeded: Int,
    val failed: Int,
    val results: List<BookOrbitBookDropFileResult>,
)
