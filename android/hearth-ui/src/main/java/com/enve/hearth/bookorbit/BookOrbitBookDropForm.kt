package com.enve.hearth.bookorbit

import com.enve.engine.bookorbit.BookOrbitBookDropEdit
import com.enve.engine.bookorbit.BookOrbitBookDropItem
import com.enve.engine.bookorbit.BookOrbitBookDropMetadata
import com.enve.engine.bookorbit.BookOrbitBookDropStatus
import java.util.Locale

private val YEAR_RANGE = 1000..2200
private val SERIES_INDEX = Regex("""\d+(\.\d+)?""")

internal data class BookOrbitBookDropForm(
    val title: String,
    val subtitle: String,
    val authors: String,
    val narrators: String,
    val seriesName: String,
    val seriesIndex: String,
    val publisher: String,
    val year: String,
    val language: String,
    val isbn13: String,
    val genres: String,
    val description: String,
    val libraryId: Int?,
    val folderId: Int?,
) {
    constructor(item: BookOrbitBookDropItem) : this(
        title = item.metadata.title,
        subtitle = item.metadata.subtitle,
        authors = item.metadata.authors.joinToString(", "),
        narrators = item.metadata.narrators.joinToString(", "),
        seriesName = item.metadata.seriesName,
        seriesIndex = item.metadata.seriesIndex,
        publisher = item.metadata.publisher,
        year = item.metadata.publishedYear?.toString().orEmpty(),
        language = item.metadata.language,
        isbn13 = item.metadata.isbn13,
        genres = item.metadata.genres.joinToString(", "),
        description = item.metadata.description,
        libraryId = item.targetLibraryId,
        folderId = item.targetFolderId,
    )

    val yearValid: Boolean get() = year.isBlank() || year.trim().toIntOrNull() in YEAR_RANGE

    val seriesIndexValid: Boolean get() = seriesIndex.isBlank() || SERIES_INDEX.matches(seriesIndex.trim())

    val valid: Boolean get() = yearValid && seriesIndexValid

    val hasDestination: Boolean get() = libraryId != null && folderId != null

    fun metadata(): BookOrbitBookDropMetadata = BookOrbitBookDropMetadata(
        title = title.trim(),
        subtitle = subtitle.trim(),
        authors = names(authors),
        narrators = names(narrators),
        description = description.trim(),
        publisher = publisher.trim(),
        publishedYear = year.trim().toIntOrNull(),
        language = language.trim(),
        isbn13 = isbn13.trim(),
        seriesName = seriesName.trim(),
        seriesIndex = seriesIndex.trim(),
        genres = names(genres),
    )

    fun changes(item: BookOrbitBookDropItem): BookOrbitBookDropEdit? {
        val edited = metadata()
        val metadataChanged = edited != BookOrbitBookDropForm(item).metadata()
        val destinationChanged = hasDestination &&
            (libraryId != item.targetLibraryId || folderId != item.targetFolderId)
        if (!metadataChanged && !destinationChanged) return null
        return BookOrbitBookDropEdit(
            metadata = edited.takeIf { metadataChanged },
            targetLibraryId = libraryId.takeIf { destinationChanged },
            targetFolderId = folderId.takeIf { destinationChanged },
        )
    }

    private fun names(text: String): List<String> =
        text.split(',', ';', '\n').map(String::trim).filter(String::isNotEmpty).distinct()
}

internal fun bookDropStatusLabel(item: BookOrbitBookDropItem): String = when (item.status) {
    BookOrbitBookDropStatus.PENDING -> "Waiting to be read"
    BookOrbitBookDropStatus.EXTRACTING -> "Reading the file"
    BookOrbitBookDropStatus.FETCHING -> "Looking up details"
    BookOrbitBookDropStatus.ERROR -> "Failed"
    BookOrbitBookDropStatus.UNKNOWN -> "Waiting for review"
    BookOrbitBookDropStatus.READY -> when (item.holdReason) {
        null -> if (item.targetLibraryId == null || item.targetFolderId == null) "Needs a destination" else "Ready to add"
        "low_confidence" -> "Needs review: weak match"
        "no_destination" -> "Needs a library"
        "no_folder" -> "Needs a folder"
        "not_allowed_in_library" -> "Format not allowed in that library"
        "duplicate" -> "Already in ${item.holdLibraryName ?: "that library"}"
        "destination_conflict" -> "A file already sits at the destination"
        "unsupported_layout" -> "Layout that library can't hold"
        "waiting_for_manager" -> "Waiting for a dock manager"
        else -> "Waiting for review"
    }
}

internal fun bookDropNeedsAttention(item: BookOrbitBookDropItem): Boolean =
    item.status == BookOrbitBookDropStatus.ERROR || (item.status == BookOrbitBookDropStatus.READY && item.holdReason != null)

internal fun bookDropFileSize(bytes: Long?): String? = when {
    bytes == null || bytes < 0L -> null
    bytes < 1_024L -> "$bytes B"
    bytes < 1_048_576L -> "${bytes / 1_024L} KB"
    bytes < 1_073_741_824L -> String.format(Locale.getDefault(), "%.1f MB", bytes / 1_048_576.0)
    else -> String.format(Locale.getDefault(), "%.2f GB", bytes / 1_073_741_824.0)
}
