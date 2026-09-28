package com.enve.bookorbit

import com.enve.bookorbit.dto.BookOrbitAnnotationDto
import com.enve.bookorbit.dto.BookOrbitBookmarkDto
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.ReaderAnnotation
import kotlin.math.roundToLong

internal const val BOOKORBIT_PROVIDER_SOURCE = "bookorbit"

private const val BOOKORBIT_ARTIFACT_COLOR = "#F5921A"

internal enum class BookOrbitArtifactPush {
    FOREIGN,
    UNSUPPORTED,
    DELETE,
    BOOKMARK,
    CREATE_HIGHLIGHT,
    UPDATE_HIGHLIGHT,
}

internal fun ReaderAnnotation.bookOrbitArtifactPush(): BookOrbitArtifactPush {
    if (providerSource != BOOKORBIT_PROVIDER_SOURCE) return BookOrbitArtifactPush.FOREIGN
    if (deletedAt != null) return BookOrbitArtifactPush.DELETE

    val artifactMedia = AnnotationMedia.parse(media)
    if (AnnotationKind.parse(kind) == AnnotationKind.BOOKMARK) {
        return when {
            artifactMedia == AnnotationMedia.AUDIOBOOK && audioPositionMs != null -> BookOrbitArtifactPush.BOOKMARK
            artifactMedia == AnnotationMedia.EPUB && !cfi.isNullOrBlank() -> BookOrbitArtifactPush.BOOKMARK
            else -> BookOrbitArtifactPush.UNSUPPORTED
        }
    }
    if (artifactMedia != AnnotationMedia.EPUB) return BookOrbitArtifactPush.UNSUPPORTED
    if (serverId?.toIntOrNull() != null) return BookOrbitArtifactPush.UPDATE_HIGHLIGHT
    return if (!cfi.isNullOrBlank() && selectedText.isNotBlank()) {
        BookOrbitArtifactPush.CREATE_HIGHLIGHT
    } else {
        BookOrbitArtifactPush.UNSUPPORTED
    }
}

internal fun ReaderAnnotation.bookOrbitCfi(): String? = cfi?.takeIf { it.isNotBlank() }?.let {
    if (it.startsWith("epubcfi(")) it else "epubcfi($it)"
}

internal fun ReaderAnnotation.bookOrbitBookmarkTitle(): String =
    note.takeIf { it.isNotBlank() }
        ?: selectedText.takeIf { it.isNotBlank() }
        ?: chapterId?.takeIf { it.isNotBlank() }
        ?: "Bookmark"

internal fun ReaderAnnotation.bookOrbitStyle(): String = when (AnnotationStyle.parse(style)) {
    AnnotationStyle.UNDERLINE -> "underline"
    AnnotationStyle.STRIKETHROUGH -> "strikethrough"
    AnnotationStyle.SQUIGGLY -> "squiggly"
    AnnotationStyle.HIGHLIGHT, AnnotationStyle.NONE -> "highlight"
}

internal fun BookOrbitAnnotationDto.toReaderAnnotationOrNull(localBookId: String): ReaderAnnotation? {
    val anchor = cfi?.takeIf { it.isNotBlank() }
    if (anchor == null && pageno == null && text.isBlank() && note.isNullOrBlank()) return null
    val created = bookOrbitDateMillis(createdAt) ?: System.currentTimeMillis()
    val pdfPage = pageno?.let { (it - 1).coerceAtLeast(0) }
    return ReaderAnnotation(
        id = "bookorbit:$id",
        bookId = localBookId,
        kind = AnnotationKind.HIGHLIGHT.name,
        media = if (pdfPage != null) AnnotationMedia.PDF.name else AnnotationMedia.EPUB.name,
        style = when (style.lowercase()) {
            "underline" -> AnnotationStyle.UNDERLINE.name
            "strikethrough" -> AnnotationStyle.STRIKETHROUGH.name
            "squiggly" -> AnnotationStyle.SQUIGGLY.name
            else -> AnnotationStyle.HIGHLIGHT.name
        },
        colorHex = color.takeIf { it.isNotBlank() } ?: BOOKORBIT_ARTIFACT_COLOR,
        cfi = anchor,
        pdfPage = pdfPage,
        selectedText = text,
        note = note.orEmpty(),
        chapterId = chapterTitle,
        createdAt = created,
        updatedAt = created,
        serverId = id.toString(),
        providerSource = BOOKORBIT_PROVIDER_SOURCE,
        syncDirty = false,
    )
}

internal fun BookOrbitBookmarkDto.toReaderAnnotationOrNull(localBookId: String): ReaderAnnotation? {
    val anchor = cfi?.takeIf { it.isNotBlank() }
    val positionMs = positionSeconds?.times(1_000.0)?.roundToLong()
    if (anchor == null && positionMs == null) return null
    val created = bookOrbitDateMillis(createdAt) ?: System.currentTimeMillis()
    return ReaderAnnotation(
        id = "bookorbit:bookmark:$id",
        bookId = localBookId,
        kind = AnnotationKind.BOOKMARK.name,
        media = if (positionMs != null) AnnotationMedia.AUDIOBOOK.name else AnnotationMedia.EPUB.name,
        style = AnnotationStyle.NONE.name,
        colorHex = BOOKORBIT_ARTIFACT_COLOR,
        audioPositionMs = positionMs,
        cfi = anchor,
        selectedText = title,
        createdAt = created,
        updatedAt = created,
        serverId = "bookmark:$id",
        providerSource = BOOKORBIT_PROVIDER_SOURCE,
        syncDirty = false,
    )
}
