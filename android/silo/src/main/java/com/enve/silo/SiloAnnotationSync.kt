package com.enve.silo

import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.sync.AcceptedAnnotation
import com.enve.core.data.sync.AnnotationsPushResult
import com.enve.core.data.sync.RejectedAnnotation
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.silo.api.SiloApi
import com.enve.silo.dto.SiloCollection
import com.enve.silo.dto.SiloReaderAnnotationCreateRequest
import com.enve.silo.dto.SiloReaderAnnotationPatchRequest
import com.enve.silo.dto.SiloReaderAnnotationRecord
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import retrofit2.Response
import java.util.Locale

internal data class SiloAnnotationContent(
    val kind: String,
    val cfiRange: String?,
    val location: String,
    val selectedText: String,
    val note: String,
    val style: String,
    val color: String,
    val metadata: Map<String, String>,
) {
    fun create(id: String) = SiloReaderAnnotationCreateRequest(id, kind, cfiRange, location, selectedText, note, style, color, metadata)

    fun patch() = SiloReaderAnnotationPatchRequest(kind, cfiRange, location, selectedText, note, style, color, metadata)

    fun matches(record: SiloReaderAnnotationRecord): Boolean =
        record.kind == kind &&
            record.cfiRange.orEmpty() == cfiRange.orEmpty() &&
            record.location.orEmpty() == location &&
            record.selectedText == selectedText &&
            record.note == note &&
            record.style == style &&
            record.color == color &&
            record.metadata.mapValues { (it.value as? JsonPrimitive)?.contentOrNull } == metadata
}

internal class SiloAnnotationSync(
    private val api: SiloApi,
    private val profileId: String,
    private val bookId: String,
) {
    private sealed interface Outcome {
        data class Accepted(val value: AcceptedAnnotation) : Outcome
        data class Rejected(val reason: String) : Outcome
        data class Conflict(val remote: SiloReaderAnnotationRecord) : Outcome
    }

    private var remote: Map<String, SiloReaderAnnotationRecord>? = null

    suspend fun records(): List<SiloReaderAnnotationRecord> = remoteIndex().values.toList()

    suspend fun push(annotations: List<ReaderAnnotation>): AnnotationsPushResult {
        val accepted = mutableListOf<AcceptedAnnotation>()
        val rejected = mutableListOf<RejectedAnnotation>()
        val conflicts = mutableListOf<ReaderAnnotation>()
        annotations.forEach { local ->
            when (val outcome = if (local.deletedAt != null) delete(local) else upsert(local)) {
                is Outcome.Accepted -> accepted += outcome.value
                is Outcome.Rejected -> rejected += RejectedAnnotation(local.id, outcome.reason)
                is Outcome.Conflict -> conflicts += outcome.remote.toReaderAnnotation(bookId)
            }
        }
        return AnnotationsPushResult(accepted = accepted, rejected = rejected, conflicts = conflicts)
    }

    suspend fun deleteRemote(serverId: String) {
        val current = remoteIndex()[serverId] ?: return
        val response = api.deleteAnnotation(profileId, current.etag, bookId, serverId)
        if (!response.isSuccessful && response.code() != 404) siloFailure("Silo annotation delete failed", response)
    }

    private suspend fun delete(local: ReaderAnnotation): Outcome {
        val serverId = local.serverId?.takeIf { it.isNotBlank() }
            ?: return Outcome.Accepted(AcceptedAnnotation(local.id))
        val etag = local.syncEtag?.takeIf(::isSiloEtag) ?: run {
            val current = remoteIndex()[serverId] ?: return Outcome.Accepted(AcceptedAnnotation(local.id, serverId))
            return Outcome.Conflict(current)
        }
        val response = api.deleteAnnotation(profileId, etag, bookId, serverId)
        if (response.isSuccessful || response.code() == 404) return Outcome.Accepted(AcceptedAnnotation(local.id, serverId))
        if (response.code() != 412) return response.rejected()
        val current = refreshed(serverId) ?: return Outcome.Accepted(AcceptedAnnotation(local.id, serverId))
        return Outcome.Conflict(current)
    }

    private suspend fun upsert(local: ReaderAnnotation): Outcome {
        val content = local.toSiloContent()
            ?: return Outcome.Rejected("Silo requires an EPUB CFI or reader location")
        val serverId = local.serverId?.takeIf { it.isNotBlank() } ?: return create(local, content)
        val etag = local.syncEtag?.takeIf(::isSiloEtag) ?: run {
            val current = remoteIndex()[serverId] ?: return Outcome.Rejected("Silo annotation was removed remotely")
            return if (content.matches(current)) current.accepted(local) else Outcome.Conflict(current)
        }
        val response = api.updateAnnotation(profileId, etag, bookId, serverId, content.patch())
        if (response.isSuccessful) {
            return response.body()?.accepted(local) ?: Outcome.Rejected("Silo returned an empty annotation")
        }
        if (response.code() != 412) return response.rejected()
        val current = refreshed(serverId) ?: return response.rejected()
        return if (content.matches(current)) current.accepted(local) else Outcome.Conflict(current)
    }

    private suspend fun create(local: ReaderAnnotation, content: SiloAnnotationContent): Outcome {
        val response = api.createAnnotation(profileId, bookId, content.create(local.id))
        if (!response.isSuccessful) return response.rejected()
        val record = response.body() ?: return Outcome.Rejected("Silo returned an empty annotation")
        return if (response.code() == 201 || content.matches(record)) record.accepted(local) else Outcome.Conflict(record)
    }

    private suspend fun remoteIndex(): Map<String, SiloReaderAnnotationRecord> =
        remote ?: siloCollectAll { cursor ->
            val response = api.annotations(profileId, bookId, cursor)
            if (response.code() == 404) SiloCollection() else response.siloBody("Silo annotations pull failed")
        }.associateBy { it.id }.also { remote = it }

    private suspend fun refreshed(serverId: String): SiloReaderAnnotationRecord? {
        remote = null
        return remoteIndex()[serverId]
    }

    private fun SiloReaderAnnotationRecord.accepted(local: ReaderAnnotation): Outcome =
        Outcome.Accepted(AcceptedAnnotation(local.id, id, etag))

    private fun Response<*>.rejected(): Outcome {
        val problem = siloProblem()
        return Outcome.Rejected("HTTP ${code()} ${problem?.id.orEmpty()}".trim())
    }
}

internal fun isSiloEtag(tag: String): Boolean = tag.startsWith("\"") || tag.startsWith("W/\"")

private val locatorJson = Json { ignoreUnknownKeys = true; isLenient = true }

private fun extractCfi(locator: String?): String? {
    EpubBridgeCheckpointCodec.cfi(locator)?.let { return it }
    val raw = locator?.trim()?.takeIf { it.isNotBlank() } ?: return null
    if (raw.startsWith("epubcfi(")) return raw
    val parsed = runCatching { locatorJson.parseToJsonElement(raw).jsonObject }.getOrNull() ?: return null
    val locations = parsed["locations"]?.jsonObject ?: return null
    val fragments = runCatching { locations["fragments"]?.jsonArray }.getOrNull()
    fragments?.firstOrNull { it.jsonPrimitive.content.startsWith("epubcfi(") }?.let { return it.jsonPrimitive.content }
    return locations["cfi"]?.jsonPrimitive?.content?.takeIf { it.startsWith("epubcfi(") }
}

private fun fraction(value: Double): String = "fraction:${"%.6f".format(Locale.US, value.coerceIn(0.0, 1.0))}"

internal fun ReaderAnnotation.toSiloContent(): SiloAnnotationContent? {
    val location = cfi?.takeIf { it.isNotBlank() }
        ?: extractCfi(locatorJson)
        ?: locatorJson?.takeIf { it.startsWith("fraction:") }
        ?: totalProgression?.let(::fraction)
        ?: progression?.let(::fraction)
        ?: return null
    val hasCfi = location.startsWith("epubcfi(")
    val parsedKind = AnnotationKind.parse(kind)
    val siloKind = when {
        parsedKind == AnnotationKind.BOOKMARK || !hasCfi -> "bookmark"
        parsedKind == AnnotationKind.NOTE -> "note"
        else -> "highlight"
    }
    return SiloAnnotationContent(
        kind = siloKind,
        cfiRange = location.takeIf { hasCfi },
        location = location,
        selectedText = selectedText,
        note = note,
        style = AnnotationStyle.parse(style).name.lowercase(),
        color = colorHex,
        metadata = buildMap {
            put("enve_local_id", id)
            put("enve_position", (totalProgression ?: progression ?: 0.0).toString())
            chapterId?.let { put("enve_chapter_title", it) }
        },
    )
}

internal fun SiloReaderAnnotationRecord.toReaderAnnotation(bookId: String): ReaderAnnotation {
    val values = metadata.mapValues { (it.value as? JsonPrimitive)?.contentOrNull }
    val localId = values["enve_local_id"]?.takeIf { it.isNotBlank() } ?: id
    val cfi = cfiRange?.takeIf { it.startsWith("epubcfi(") }
        ?: location?.takeIf { it.startsWith("epubcfi(") }
    val progression = values["enve_position"]?.toDoubleOrNull()
    val now = System.currentTimeMillis()
    return ReaderAnnotation(
        id = localId,
        bookId = bookId,
        kind = when (kind.lowercase()) {
            "bookmark" -> AnnotationKind.BOOKMARK.name
            "note" -> AnnotationKind.NOTE.name
            else -> AnnotationKind.HIGHLIGHT.name
        },
        media = AnnotationMedia.EPUB.name,
        style = AnnotationStyle.parse(style.uppercase()).name,
        colorHex = color.ifBlank { "#facc15" },
        locatorJson = siloNavigatorLocator(location ?: cfi, progression ?: 0.0),
        cfi = cfi,
        progression = progression,
        totalProgression = progression,
        selectedText = selectedText,
        note = note,
        chapterId = values["enve_chapter_title"]?.takeIf { it.isNotBlank() },
        createdAt = siloInstantMillis(createdAt) ?: now,
        updatedAt = siloInstantMillis(updatedAt) ?: now,
        serverId = id,
        providerSource = BookSource.SILO.displayName.lowercase(),
        syncDirty = false,
        syncEtag = etag,
    )
}
