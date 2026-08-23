package com.enve.core.data.sync

import com.enve.core.data.model.ReaderAnnotation
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import org.json.JSONArray

@Serializable
data class AnnotationDto(
    val id: String,
    val kind: String,
    val media: String,
    val style: String,
    val colorHex: String,
    val locatorJson: JsonElement? = null,
    val pdfPage: Int? = null,
    val pdfRectsJson: String? = null,
    val cbzPage: Int? = null,
    val audioPositionMs: Long? = null,
    val chapterId: String? = null,
    val cfi: String? = null,
    val cssSelector: String? = null,
    val textQuoteExact: String? = null,
    val textQuotePrefix: String? = null,
    val textQuoteSuffix: String? = null,
    val progression: Double? = null,
    val totalProgression: Double? = null,
    val selectedText: String = "",
    val note: String = "",
    val tagsJson: String = "[]",
    val attachmentUriString: String? = null,
    val attachmentKind: String? = null,
    val createdAt: Long,
    val updatedAt: Long,
    val deletedAt: Long? = null,
    @SerialName("etag") val etag: String? = null,
    @SerialName("serverId") val serverId: String? = null,
)

@Serializable
data class AnnotationsBatchRequest(
    val annotations: List<AnnotationDto>,
)

@Serializable
data class AnnotationsBatchResponse(
    val accepted: List<AcceptedAnnotation> = emptyList(),
    val rejected: List<RejectedAnnotation> = emptyList(),
    val conflicts: List<AnnotationDto> = emptyList(),
)

@Serializable
data class AcceptedAnnotation(
    val id: String,
    val serverId: String? = null,
    val etag: String? = null,
)

@Serializable
data class RejectedAnnotation(
    val id: String,
    val reason: String,
)

@Serializable
data class AnnotationsListResponse(
    val annotations: List<AnnotationDto> = emptyList(),
    val serverTime: Long = 0,
)

object AnnotationsWireFormat {
    val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
        explicitNulls = false
    }

    fun toDto(a: ReaderAnnotation): AnnotationDto {
        val locElement: JsonElement? = a.locatorJson?.let {
            runCatching { json.parseToJsonElement(it) }.getOrNull()
        }
        return AnnotationDto(
            id = a.id,
            kind = a.kind,
            media = a.media,
            style = a.style,
            colorHex = a.colorHex,
            locatorJson = locElement,
            pdfPage = a.pdfPage,
            pdfRectsJson = a.pdfRectsJson,
            cbzPage = a.cbzPage,
            audioPositionMs = a.audioPositionMs,
            chapterId = a.chapterId,
            cfi = a.cfi,
            cssSelector = a.cssSelector,
            textQuoteExact = a.textQuoteExact,
            textQuotePrefix = a.textQuotePrefix,
            textQuoteSuffix = a.textQuoteSuffix,
            progression = a.progression,
            totalProgression = a.totalProgression,
            selectedText = a.selectedText,
            note = a.note,
            tagsJson = a.tagsJson,
            attachmentUriString = a.attachmentUriString,
            attachmentKind = a.attachmentKind,
            createdAt = a.createdAt,
            updatedAt = a.updatedAt,
            deletedAt = a.deletedAt,
            etag = a.syncEtag,
            serverId = a.serverId,
        )
    }

    fun fromDto(dto: AnnotationDto, bookId: String, providerSource: String): ReaderAnnotation {
        val locStr = dto.locatorJson?.let { json.encodeToString(JsonElement.serializer(), it) }
        return ReaderAnnotation(
            id = dto.id,
            bookId = bookId,
            kind = dto.kind,
            media = dto.media,
            style = dto.style,
            colorHex = dto.colorHex,
            locatorJson = locStr,
            pdfPage = dto.pdfPage,
            pdfRectsJson = dto.pdfRectsJson,
            cbzPage = dto.cbzPage,
            audioPositionMs = dto.audioPositionMs,
            chapterId = dto.chapterId,
            cfi = dto.cfi,
            cssSelector = dto.cssSelector,
            textQuoteExact = dto.textQuoteExact,
            textQuotePrefix = dto.textQuotePrefix,
            textQuoteSuffix = dto.textQuoteSuffix,
            progression = dto.progression,
            totalProgression = dto.totalProgression,
            selectedText = dto.selectedText,
            note = dto.note,
            tagsJson = dto.tagsJson,
            attachmentUriString = dto.attachmentUriString,
            attachmentKind = dto.attachmentKind,
            createdAt = dto.createdAt,
            updatedAt = dto.updatedAt,
            deletedAt = dto.deletedAt,
            serverId = dto.serverId ?: dto.id,
            providerSource = providerSource,
            syncDirty = false,
            syncEtag = dto.etag,
        )
    }
}

data class AnnotationsPushResult(
    val accepted: List<AcceptedAnnotation> = emptyList(),
    val rejected: List<RejectedAnnotation> = emptyList(),
    val conflicts: List<ReaderAnnotation> = emptyList(),
) {
    val isSuccess: Boolean get() = rejected.isEmpty()
}
