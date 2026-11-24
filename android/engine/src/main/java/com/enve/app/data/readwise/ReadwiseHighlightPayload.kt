package com.enve.app.data.readwise

import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.ReaderAnnotation
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.security.MessageDigest
import java.time.Instant

@Serializable
internal data class ReadwiseHighlightPayload(
    val text: String,
    val title: String? = null,
    val author: String? = null,
    @SerialName("source_type") val sourceType: String,
    val category: String,
    val note: String? = null,
    val location: Long? = null,
    @SerialName("location_type") val locationType: String? = null,
    @SerialName("highlighted_at") val highlightedAt: String,
) {
    fun update() = ReadwiseHighlightUpdate(text, note.orEmpty(), location, locationType)

    companion object {
        const val SOURCE_TYPE = "enve_book_player"
        const val CATEGORY = "books"
    }
}

@Serializable
internal data class ReadwiseHighlightUpdate(
    val text: String,
    val note: String,
    val location: Long? = null,
    @SerialName("location_type") val locationType: String? = null,
)

@Serializable
internal data class ReadwiseCreateHighlightsRequest(val highlights: List<ReadwiseHighlightPayload>)

internal data class ReadwiseBookInfo(val title: String?, val author: String?)

internal data class ReadwiseCatalogBook(val source: String, val title: String?, val author: String?)

internal object ReadwiseHighlightMapper {
    private const val TEXT_LIMIT = 8191
    private const val NOTE_LIMIT = 8191
    private const val TITLE_LIMIT = 511
    private const val AUTHOR_LIMIT = 1024

    fun isExportable(annotation: ReaderAnnotation): Boolean =
        annotation.deletedAt == null &&
            AnnotationKind.parse(annotation.kind) != AnnotationKind.BOOKMARK &&
            annotation.selectedText.isNotBlank()

    fun fitsLimits(payload: ReadwiseHighlightPayload): Boolean =
        payload.text.codePointLength() <= TEXT_LIMIT && (payload.note?.codePointLength() ?: 0) <= NOTE_LIMIT

    fun bookInfo(candidates: List<ReadwiseCatalogBook>, providerSource: String): ReadwiseBookInfo? =
        candidates
            .filter { it.source.equals(providerSource, ignoreCase = true) }
            .map { ReadwiseBookInfo(it.title.bounded(TITLE_LIMIT), it.author.bounded(AUTHOR_LIMIT)) }
            .distinct()
            .singleOrNull()

    fun payload(annotation: ReaderAnnotation, book: ReadwiseBookInfo?): ReadwiseHighlightPayload {
        val (location, locationType) = location(annotation)
        return ReadwiseHighlightPayload(
            text = annotation.selectedText.trim(),
            title = book?.title,
            author = book?.author,
            sourceType = ReadwiseHighlightPayload.SOURCE_TYPE,
            category = ReadwiseHighlightPayload.CATEGORY,
            note = annotation.note.trim().takeIf { it.isNotEmpty() },
            location = location,
            locationType = locationType,
            highlightedAt = Instant.ofEpochMilli(annotation.createdAt).toString(),
        )
    }

    fun fingerprint(payload: ReadwiseHighlightPayload): String =
        sha256(listOf(payload.text, payload.note.orEmpty(), payload.location?.toString().orEmpty(), payload.locationType.orEmpty()).joinToString("\u0000"))

    fun accountFingerprint(token: String): String = sha256("readwise:$token")

    private fun location(annotation: ReaderAnnotation): Pair<Long?, String?> =
        when (AnnotationMedia.parse(annotation.media)) {
            AnnotationMedia.PDF -> annotation.pdfPage?.takeIf { it >= 0 }?.let { it + 1L to "page" }
            AnnotationMedia.CBZ -> annotation.cbzPage?.takeIf { it >= 0 }?.let { it + 1L to "page" }
            AnnotationMedia.AUDIOBOOK -> annotation.audioPositionMs?.takeIf { it >= 0 }?.let { it / 1000 to "time_offset" }
            AnnotationMedia.EPUB -> null
        } ?: (null to null)

    private fun String.codePointLength(): Int = codePointCount(0, length)

    private fun String?.bounded(limit: Int): String? {
        val value = this?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return if (value.codePointLength() <= limit) value else value.substring(0, value.offsetByCodePoints(0, limit))
    }

    private fun sha256(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}
