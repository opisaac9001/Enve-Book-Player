package com.enve.storyteller.dto

import kotlinx.serialization.KSerializer
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.JsonElement

@Serializable
data class StorytellerTokenResponse(
    val access_token: String,
    val expires_in: Long? = null,
    val token_type: String? = null,
)

@Serializable
data class StorytellerAppTokenRequest(val token: String)

@Serializable
data class StorytellerBookDto(
    val uuid: String = "",
    val title: String = "",
    val subtitle: String? = null,
    val description: String? = null,
    val language: String? = null,
    val rating: Double? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
    val publicationDate: String? = null,
    val suffix: String? = null,
    val authors: List<StorytellerCreatorDto>? = null,
    val narrators: List<StorytellerCreatorDto>? = null,
    val series: List<StorytellerSeriesRelationDto>? = null,
    val tags: List<StorytellerTagDto>? = null,
    val collections: List<StorytellerCollectionRefDto>? = null,
    val status: StorytellerStatusDto? = null,
    val position: StorytellerPositionResponse? = null,
    val ebook: StorytellerFormatDto? = null,
    val audiobook: StorytellerFormatDto? = null,
    val readaloud: StorytellerReadaloudDto? = null,
)

@Serializable
data class StorytellerCreatorDto(
    val uuid: String = "",
    val name: String = "",
    val fileAs: String? = null,
)

@Serializable
data class StorytellerSeriesRelationDto(
    val uuid: String = "",
    val name: String = "",
    val position: Double? = null,
)

@Serializable
data class StorytellerTagDto(
    val uuid: String = "",
    val name: String = "",
)

@Serializable
data class StorytellerCollectionRefDto(
    val uuid: String = "",
    val name: String? = null,
)

@Serializable
data class StorytellerStatusDto(
    val uuid: String = "",
    val name: String = "",
    @Serializable(with = LenientBooleanSerializer::class)
    val isDefault: Boolean? = null,
)

@Serializable
data class StorytellerFormatDto(
    val uuid: String = "",
    val filepath: String? = null,
    @Serializable(with = LenientIntSerializer::class)
    val missing: Int? = null,
)

@Serializable
data class StorytellerReadaloudDto(
    val uuid: String = "",
    val filepath: String? = null,
    val status: String? = null,
    @Serializable(with = LenientIntSerializer::class)
    val missing: Int? = null,
    val currentStage: String? = null,

    val stageProgress: Double? = null,
    val queuePosition: Int? = null,
    @Serializable(with = LenientBooleanSerializer::class)
    val restartPending: Boolean? = null,
) {
    val isReady: Boolean
        get() = status == "ALIGNED" && !filepath.isNullOrBlank() && (missing == null || missing == 0)
}

@Serializable
data class StorytellerPositionResponse(
    val uuid: String? = null,
    val timestamp: Long = 0L,
    val locator: JsonElement? = null,
)

@Serializable
data class StorytellerPositionRequest(
    val locator: JsonElement,
    val timestamp: Long,
)

@Serializable
data class StorytellerUserDto(
    val id: String = "",
    val name: String? = null,
    val username: String = "",
    val email: String? = null,
)

@Serializable
data class StorytellerCollectionDto(
    val uuid: String = "",
    val name: String = "",
    val description: String? = null,
    val books: List<StorytellerBookRefDto>? = null,
)

@Serializable
data class StorytellerBookRefDto(val uuid: String = "")

@Serializable
data class StorytellerSeriesDto(
    val uuid: String = "",
    val name: String = "",
    val description: String? = null,
    val books: List<StorytellerSeriesBookRefDto>? = null,
)

@Serializable
data class StorytellerSeriesBookRefDto(
    val uuid: String = "",
    val position: Double? = null,
)

@Serializable
data class StorytellerAudioManifestDto(
    val readingOrder: List<StorytellerAudioItemDto> = emptyList(),
    val toc: List<StorytellerTocItemDto>? = null,
)

@Serializable
data class StorytellerAudioItemDto(
    val href: String,
    val type: String? = null,
    val duration: Double? = null,
)

@Serializable
data class StorytellerTocItemDto(
    val href: String? = null,
    val title: String? = null,
)

@Serializable
data class StorytellerShelfDto(
    val uuid: String = "",
    val userId: String? = null,
    val name: String = "",
    val description: String? = null,
    val filter: JsonElement? = null,
    val orderBy: String? = null,
    val orderDirection: String? = null,
    val limitCount: Int? = null,
    val icon: String? = null,
    val color: String? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
    val books: List<StorytellerShelfBookDto>? = null,
)

@Serializable
data class StorytellerShelfBookDto(
    val bookUuid: String = "",
    val position: Int? = null,
)

@Serializable
data class StorytellerAlignmentFacetsDto(
    val grades: Map<String, Int> = emptyMap(),
    val total: Int = 0,
    val muted: Int = 0,
)

@Serializable
data class StorytellerAlignmentReportDto(
    val bookUuid: String = "",
    val bookTitle: String? = null,
    val reportUuid: String = "",
    val createdAt: String? = null,
    val summary: StorytellerAlignmentSummaryDto = StorytellerAlignmentSummaryDto(),
    val totalAudioDuration: Double = 0.0,
    val alignedAudioDuration: Double = 0.0,
    val totalSentences: Int = 0,
    val alignedSentences: Int = 0,
    val significantChapters: Int = 0,
    val chapters: List<StorytellerAlignmentChapterDto> = emptyList(),
    val unalignedChapters: List<StorytellerUnalignedChapterDto> = emptyList(),
    val unalignedAudioFiles: List<StorytellerUnalignedAudioFileDto> = emptyList(),
)

@Serializable
data class StorytellerAlignmentSummaryDto(
    val grade: String = "",
    val score: Double? = null,
    val chapters: Int = 0,
    val missingSentences: Int = 0,
    val mutedChapters: Int = 0,
    val failedChapters: Int = 0,
    val unalignedAudio: Int = 0,
)

@Serializable
data class StorytellerAlignmentChapterDto(
    val href: String = "",
    val label: String = "",
    val title: String? = null,
    val chapterSentenceCount: Int = 0,
    val alignedSentenceCount: Int = 0,
    val coverage: Double? = null,
    val delta: Double = 0.0,
    val deltaPct: Double = 0.0,
    @Serializable(with = LenientBooleanSerializer::class)
    val flagged: Boolean? = null,
    val flags: List<StorytellerAlignmentFlagDto> = emptyList(),
    @Serializable(with = LenientBooleanSerializer::class)
    val markedOk: Boolean? = null,
    @Serializable(with = LenientBooleanSerializer::class)
    val excludedFromScore: Boolean? = null,
)

@Serializable
data class StorytellerAlignmentFlagDto(
    val label: String = "",
    val tone: String = "",
)

@Serializable
data class StorytellerUnalignedChapterDto(
    val href: String = "",
    val label: String = "",
    val reason: String = "",
    val preview: String? = null,
    @Serializable(with = LenientBooleanSerializer::class)
    val intended: Boolean? = null,
)

@Serializable
data class StorytellerUnalignedAudioFileDto(
    val filepath: String = "",
    val title: String? = null,
    val duration: Double? = null,
    val transcription: String? = null,
    @Serializable(with = LenientBooleanSerializer::class)
    val excluded: Boolean? = null,
)

@Serializable
data class StorytellerStatusUpdateRequest(
    val status: String,
)

@Serializable
data class StorytellerRatingUpdateRequest(
    val rating: Int,
)

@OptIn(ExperimentalSerializationApi::class)
private object LenientIntSerializer : KSerializer<Int?> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("LenientInt", PrimitiveKind.INT)

    override fun serialize(encoder: Encoder, value: Int?) {
        if (value == null) {
            encoder.encodeNull()
        } else {
            encoder.encodeInt(value)
        }
    }

    override fun deserialize(decoder: Decoder): Int? {
        val jsonDecoder = decoder as? JsonDecoder ?: return runCatching { decoder.decodeInt() }.getOrNull()
        return when (val element = jsonDecoder.decodeJsonElement()) {
            JsonNull -> null
            is JsonPrimitive -> element.intOrNull
                ?: element.booleanOrNull?.let { if (it) 1 else 0 }
                ?: element.contentOrNull?.toIntOrNull()
            else -> null
        }
    }
}

@OptIn(ExperimentalSerializationApi::class)
private object LenientBooleanSerializer : KSerializer<Boolean?> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("LenientBoolean", PrimitiveKind.BOOLEAN)

    override fun serialize(encoder: Encoder, value: Boolean?) {
        if (value == null) {
            encoder.encodeNull()
        } else {
            encoder.encodeBoolean(value)
        }
    }

    override fun deserialize(decoder: Decoder): Boolean? {
        val jsonDecoder = decoder as? JsonDecoder ?: return runCatching { decoder.decodeBoolean() }.getOrNull()
        return when (val element = jsonDecoder.decodeJsonElement()) {
            JsonNull -> null
            is JsonPrimitive -> element.booleanOrNull
                ?: element.intOrNull?.let { it != 0 }
                ?: element.contentOrNull?.toIntOrNull()?.let { it != 0 }
            else -> null
        }
    }
}
