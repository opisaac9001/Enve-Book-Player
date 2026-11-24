package com.enve.app.hearth

import com.enve.bookorbit.BookOrbitDockAccess
import com.enve.bookorbit.BookOrbitRequestException
import com.enve.bookorbit.bookOrbitDockMetadata
import com.enve.bookorbit.bookOrbitEffectiveDockMetadata
import com.enve.bookorbit.dto.BookOrbitBookDockApplyFetchedDto
import com.enve.bookorbit.dto.BookOrbitBookDockFileDto
import com.enve.bookorbit.dto.BookOrbitBookDockFilesPageDto
import com.enve.bookorbit.dto.BookOrbitBookDockFinalizeDto
import com.enve.bookorbit.dto.BookOrbitBookDockMetadataDto
import com.enve.bookorbit.dto.BookOrbitBookDockSummaryDto
import com.enve.bookorbit.dto.BookOrbitLibraryDto
import com.enve.bookorbit.dto.BookOrbitSmartScopeDto
import com.enve.engine.bookorbit.BookOrbitBookDropAccess
import com.enve.engine.bookorbit.BookOrbitBookDropApplied
import com.enve.engine.bookorbit.BookOrbitBookDropApproval
import com.enve.engine.bookorbit.BookOrbitBookDropFileResult
import com.enve.engine.bookorbit.BookOrbitBookDropFolder
import com.enve.engine.bookorbit.BookOrbitBookDropItem
import com.enve.engine.bookorbit.BookOrbitBookDropLibrary
import com.enve.engine.bookorbit.BookOrbitBookDropMetadata
import com.enve.engine.bookorbit.BookOrbitBookDropPage
import com.enve.engine.bookorbit.BookOrbitBookDropStatus
import com.enve.engine.bookorbit.BookOrbitBookDropSummary
import com.enve.engine.bookorbit.BookOrbitFailureReason
import com.enve.engine.bookorbit.BookOrbitSmartScope
import com.enve.engine.bookorbit.BookOrbitToolException

private val UNSUPPORTED_STATUSES = setOf(404, 405, 501)

internal fun Throwable.toBookOrbitToolException(): BookOrbitToolException = when (this) {
    is BookOrbitToolException -> this
    is BookOrbitRequestException -> BookOrbitToolException(
        reason = when (httpStatus) {
            401 -> BookOrbitFailureReason.UNAUTHORIZED
            403 -> BookOrbitFailureReason.FORBIDDEN
            in UNSUPPORTED_STATUSES -> BookOrbitFailureReason.UNSUPPORTED
            in 400..499 -> BookOrbitFailureReason.REJECTED
            else -> BookOrbitFailureReason.UNREACHABLE
        },
        serverMessage = serverMessage,
    )
    is IllegalArgumentException -> BookOrbitToolException(BookOrbitFailureReason.REJECTED, message)
    else -> BookOrbitToolException(BookOrbitFailureReason.UNREACHABLE)
}

internal fun BookOrbitSmartScopeDto.toSmartScope(): BookOrbitSmartScope = BookOrbitSmartScope(
    id = id,
    name = name.ifBlank { "Smart scope $id" },
    bookCount = bookCount,
    shared = !isOwner,
)

internal fun BookOrbitDockAccess.toBookDropAccess(): BookOrbitBookDropAccess = BookOrbitBookDropAccess(
    canView = canView,
    canApprove = canFinalize,
    managesAll = managesAll,
)

internal fun BookOrbitBookDockMetadataDto.toBookDropMetadata(): BookOrbitBookDropMetadata = BookOrbitBookDropMetadata(
    title = title.orEmpty(),
    subtitle = subtitle.orEmpty(),
    authors = authors,
    narrators = narrators,
    description = description.orEmpty(),
    publisher = publisher.orEmpty(),
    publishedYear = publishedYear,
    language = language.orEmpty(),
    isbn13 = isbn13.orEmpty(),
    seriesName = seriesName.orEmpty(),
    seriesIndex = seriesIndex.orEmpty(),
    genres = genres,
)

internal fun BookOrbitBookDropMetadata.toDockMetadata(): BookOrbitBookDockMetadataDto = BookOrbitBookDockMetadataDto(
    title = title,
    subtitle = subtitle,
    authors = authors,
    narrators = narrators,
    description = description,
    publisher = publisher,
    publishedYear = publishedYear,
    language = language,
    isbn13 = isbn13,
    seriesName = seriesName,
    seriesIndex = seriesIndex,
    genres = genres,
)

internal fun BookOrbitBookDockFileDto.toBookDropItem(): BookOrbitBookDropItem = BookOrbitBookDropItem(
    id = id,
    fileName = fileName,
    fileSizeBytes = fileSize,
    format = format?.takeIf { it.isNotBlank() },
    status = when (status.lowercase()) {
        "pending" -> BookOrbitBookDropStatus.PENDING
        "extracting" -> BookOrbitBookDropStatus.EXTRACTING
        "fetching" -> BookOrbitBookDropStatus.FETCHING
        "ready" -> BookOrbitBookDropStatus.READY
        "error" -> BookOrbitBookDropStatus.ERROR
        else -> BookOrbitBookDropStatus.UNKNOWN
    },
    metadata = bookOrbitEffectiveDockMetadata(this).toBookDropMetadata(),
    embedded = bookOrbitDockMetadata(embeddedMetadata)?.toBookDropMetadata(),
    fetched = bookOrbitDockMetadata(fetchedMetadata)?.toBookDropMetadata(),
    edited = metadataEditedAt != null,
    targetLibraryId = targetLibraryId,
    targetFolderId = targetFolderId,
    confidence = confidence,
    errorMessage = errorMessage?.takeIf { it.isNotBlank() },
    holdReason = holdReason?.takeIf { it.isNotBlank() },
    holdLibraryName = holdDetail?.libraryName?.takeIf { it.isNotBlank() },
    formerLibraryName = formerLibraryName?.takeIf { it.isNotBlank() },
    alsoIn = alsoIn.filter { it.isNotBlank() },
)

internal fun BookOrbitBookDockFilesPageDto.toBookDropPage(): BookOrbitBookDropPage = BookOrbitBookDropPage(
    items = items.map { it.toBookDropItem() },
    total = total,
    page = page,
)

internal fun BookOrbitBookDockSummaryDto.toBookDropSummary(): BookOrbitBookDropSummary = BookOrbitBookDropSummary(
    pending = pending,
    ready = ready,
    error = error,
    needsReview = needsReview,
    total = total,
    paused = paused,
)

internal fun BookOrbitLibraryDto.toBookDropLibrary(): BookOrbitBookDropLibrary = BookOrbitBookDropLibrary(
    id = id,
    name = name,
    folders = folders.map { BookOrbitBookDropFolder(it.id, it.path) },
    allowedFormats = allowedFormats,
)

internal fun BookOrbitBookDockApplyFetchedDto.toBookDropApplied(): BookOrbitBookDropApplied = BookOrbitBookDropApplied(
    applied = applied,
    skippedEdited = skippedEdited,
    skipped = skipped,
)

internal fun BookOrbitBookDockFinalizeDto.toBookDropApproval(): BookOrbitBookDropApproval = BookOrbitBookDropApproval(
    total = total,
    succeeded = succeeded,
    failed = failed,
    results = results.map { result ->
        BookOrbitBookDropFileResult(
            fileId = result.fileId,
            fileName = result.newName?.takeIf { it.isNotBlank() } ?: result.fileName,
            success = result.success,
            duplicate = result.isDuplicate,
            message = result.message?.takeIf { it.isNotBlank() },
        )
    },
)
