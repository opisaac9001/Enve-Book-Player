package com.enve.app.data.librarian

import com.enve.app.document.EbookSourceFormat
import com.enve.core.data.model.BookSource
import kotlinx.serialization.Serializable
import java.util.UUID

enum class BookIntelligenceScope {
    PREVIOUS_CHAPTER,
    CURRENT_CHAPTER_SO_FAR,
    RECENT_PAGES,
    BOOK_SO_FAR;

    val title: String
        get() = when (this) {
            PREVIOUS_CHAPTER -> "Previous Chapter"
            CURRENT_CHAPTER_SO_FAR -> "This Chapter"
            RECENT_PAGES -> "Recent Pages"
            BOOK_SO_FAR -> "Book So Far"
        }

    val promptName: String
        get() = when (this) {
            PREVIOUS_CHAPTER -> "the previous chapter"
            CURRENT_CHAPTER_SO_FAR -> "the current chapter up to the current reading position"
            RECENT_PAGES -> "the recent pages before the current reading position"
            BOOK_SO_FAR -> "the book so far"
        }
}

enum class BookContextStatus {
    MISSING,
    READY,
    GENERATING,
    FAILED,
}

enum class LibrarianEnginePreference {
    AUTOMATIC,
    REMOTE_SERVER,
    GEMINI_NANO,
    LITERT_LM,
    LOCAL_EXTRACTIVE;

    val title: String
        get() = when (this) {
            AUTOMATIC -> "Automatic"
            REMOTE_SERVER -> "Local Server"
            GEMINI_NANO -> "Gemini Nano"
            LITERT_LM -> "Local Model"
            LOCAL_EXTRACTIVE -> "Basic Local"
        }
}

enum class LibrarianEngineAvailability {
    AVAILABLE,
    DOWNLOADABLE,
    DOWNLOADING,
    MODEL_MISSING,
    UNAVAILABLE,
}

data class LibrarianEngineStatus(
    val preference: LibrarianEnginePreference,
    val availability: LibrarianEngineAvailability,
    val title: String,
    val detail: String,
    val isUsable: Boolean,
)

data class RecommendedLibrarianModel(
    val title: String,
    val detail: String,
    val sizeBytes: Long,
)

data class LibrarianModelDownloadState(
    val isActive: Boolean,
    val progress: Double?,
    val errorMessage: String?,
)

data class LibrarianAnswer(
    val text: String,
    val engineTitle: String,
)

@Serializable
data class LibrarianBookRef(
    val bookId: String,
    val sourceName: String,
    val connectionId: String?,
    val title: String,
    val author: String?,
    val formatName: String?,
    val currentProgress: Double,
) {
    val source: BookSource
        get() = runCatching { BookSource.valueOf(sourceName) }.getOrDefault(BookSource.GRIMMORY)

    val sourceFormat: EbookSourceFormat
        get() = EbookSourceFormat.fromServerType(formatName).let { format ->
            if (format == EbookSourceFormat.UNKNOWN) EbookSourceFormat.EPUB else format
        }

    val stableId: String
        get() = listOfNotNull(connectionId, sourceName, bookId).joinToString(":")

    val legacyStableId: String
        get() = "$sourceName:$bookId"
}

@Serializable
data class EbookContextManifest(
    val bookStableId: String,
    val status: BookContextStatus,
    val createdAtEpochMs: Long,
    val updatedAtEpochMs: Long,
    val chunkCount: Int,
    val failureMessage: String? = null,
)

@Serializable
data class EbookContextChunk(
    val id: String,
    val bookStableId: String,
    val title: String?,
    val href: String?,
    val index: Int,
    val startProgress: Double,
    val endProgress: Double,
    val text: String,
)

@Serializable
data class EbookContext(
    val manifest: EbookContextManifest,
    val chunks: List<EbookContextChunk>,
)

data class BookContextResult(
    val scope: BookIntelligenceScope,
    val rangeStart: Double,
    val rangeEnd: Double,
    val text: String,
    val chunkCount: Int,
) {
    val isEmpty: Boolean
        get() = text.isBlank()
}

@Serializable
data class LibrarianMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: LibrarianMessageRole,
    val text: String,
    val scope: BookIntelligenceScope? = null,
    val engineTitle: String? = null,
    val createdAtEpochMs: Long = System.currentTimeMillis(),
)

@Serializable
enum class LibrarianMessageRole {
    USER,
    ASSISTANT,
}
