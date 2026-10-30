package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.BookSummaryDto
import com.enve.app.data.remote.dto.LegacyBookloreBookDto
import com.enve.core.data.provider.CatalogFailure
import com.enve.core.data.provider.CatalogFailureKind
import com.enve.core.data.provider.CatalogImportReport
import com.enve.core.data.provider.CatalogImportStage
import com.enve.core.data.provider.CatalogRejectionReason
import java.io.IOException
import javax.inject.Inject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.longOrNull
import retrofit2.Response

internal data class GrimmoryCatalogBatch(
    val books: List<BookSummaryDto> = emptyList(),
    val report: CatalogImportReport = CatalogImportReport(),
)

@Serializable
private data class CatalogPage(
    val content: JsonArray,
    val totalPages: Int = 1,
    val totalElements: Int? = null,
    val size: Int? = null,
)

class GrimmoryCatalogFetcher(
    private val api: GrimmoryApi,
    private val json: Json,
) {
    @Inject constructor(api: GrimmoryApi) : this(api, Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        isLenient = true
    })

    internal suspend fun fetch(libraryId: String?, page: Int, size: Int, sort: String, dir: String): GrimmoryCatalogBatch = coroutineScope {
        val stage = CatalogImportStage.BOOKS
        val effectiveSize = size.coerceIn(1, 500)
        val first = try {
            api.getCatalogBooks(libraryId, page, effectiveSize, sort, dir).catalogResponse()
        } catch (e: Exception) {
            return@coroutineScope failed(e, stage, page)
        }
        if (first.code() in listOf(401, 403)) return@coroutineScope failed(first, stage, page)
        if (!first.isSuccessful) return@coroutineScope legacy(libraryId)
        val envelope = try {
            json.decodeFromJsonElement<CatalogPage>(first.body() ?: JsonNull)
        } catch (e: SerializationException) {
            return@coroutineScope failed(e, stage, page)
        }
        if (envelope.totalPages !in 0..10000 || (envelope.totalPages == 0 && envelope.content.isNotEmpty()) || envelope.size?.let { it <= 0 } == true) {
            return@coroutineScope GrimmoryCatalogBatch(report = problem(CatalogFailureKind.INVALID_PAGINATION, stage, page))
        }
        if (page == 0 && envelope.content.isEmpty()) {
            val fallback = legacy(libraryId)
            return@coroutineScope if ((envelope.totalElements ?: 0) > 0 && fallback.books.isEmpty()) {
                fallback.copy(report = fallback.report.merge(problem(CatalogFailureKind.CONFLICTING_CATALOG, stage)))
            } else fallback
        }
        val initial = decode(envelope.content, BookSummaryDto.serializer(), libraryId) { it.libraryId }
        val semaphore = Semaphore(8)
        val rest = ((page + 1) until envelope.totalPages).map { next ->
            async {
                semaphore.withPermit {
                    try {
                        val response = api.getCatalogBooks(libraryId, next, envelope.size ?: effectiveSize, sort, dir).catalogResponse()
                        if (!response.isSuccessful) return@withPermit failed(response, stage, next)
                        val body = json.decodeFromJsonElement<CatalogPage>(response.body() ?: JsonNull)
                        if (body.totalPages != envelope.totalPages || body.content.isEmpty()) {
                            return@withPermit GrimmoryCatalogBatch(report = problem(CatalogFailureKind.INVALID_PAGINATION, stage, next))
                        }
                        val decoded = decode(body.content, BookSummaryDto.serializer(), libraryId) { it.libraryId }
                        GrimmoryCatalogBatch(decoded.first, decoded.second)
                    } catch (e: Exception) {
                        failed(e, stage, next)
                    }
                }
            }
        }.awaitAll()
        val books = initial.first + rest.flatMap { it.books }
        var report = rest.fold(initial.second) { accumulated, batch -> accumulated.merge(batch.report) }
        val unique = books.distinctBy { it.id }
        if (unique.size != books.size || (page == 0 && envelope.totalElements?.let { it != books.size + report.rejectedCount } == true)) {
            report = report.merge(problem(CatalogFailureKind.INVALID_PAGINATION, stage))
        }
        formats(GrimmoryCatalogBatch(unique, report), libraryId)
    }

    private suspend fun formats(batch: GrimmoryCatalogBatch, libraryId: String?): GrimmoryCatalogBatch {
        val resolved = mutableListOf<BookSummaryDto>()
        var report = batch.report
        for (group in batch.books.chunked(100)) {
            val response = try {
                api.getCatalogInventory(group.joinToString(",") { it.id }).catalogResponse()
            } catch (e: Exception) {
                report = report.merge(failed(e, CatalogImportStage.FORMATS).report)
                break
            }
            if (resolved.isEmpty() && response.code() in listOf(404, 405)) {
                val fallback = legacy(libraryId)
                val consistent = try {
                    consistentGrimmoryCatalogFallback(batch.books, fallback.books)
                    true
                } catch (_: IllegalStateException) { false }
                return if (consistent) fallback.copy(report = report.merge(fallback.report)) else GrimmoryCatalogBatch(
                    batch.books.filter { it.hasAudioFormat() || it.hasEbookFormat() },
                    report.merge(fallback.report).merge(problem(CatalogFailureKind.CONFLICTING_CATALOG, CatalogImportStage.LEGACY)),
                )
            }
            if (!response.isSuccessful) {
                report = report.merge(failed(response, CatalogImportStage.FORMATS).report)
                break
            }
            val decoded = try {
                decode(response.body() as? JsonArray ?: throw SerializationException(), LegacyBookloreBookDto.serializer(), libraryId) { it.libraryId }
            } catch (e: SerializationException) {
                report = report.merge(failed(e, CatalogImportStage.FORMATS).report)
                break
            }
            val byId = decoded.first.associateBy { it.id }
            report = report.merge(decoded.second)
            val missing = group.count { it.id !in byId }
            report = report.rejecting(CatalogRejectionReason.MISSING_INVENTORY, (missing - decoded.second.rejectedCount).coerceAtLeast(0))
            group.forEach { summary ->
                byId[summary.id]?.let { inventory ->
                    val enriched = summary.withFormatInventory(inventory)
                    resolved += if (enriched.libraryId == null) enriched.copy(libraryId = libraryId) else enriched
                }
            }
        }
        return GrimmoryCatalogBatch(resolved.distinctBy { it.id }, report.copy(acceptedCount = resolved.distinctBy { it.id }.size))
    }

    private suspend fun legacy(libraryId: String?): GrimmoryCatalogBatch {
        val ids = if (libraryId != null) listOf(libraryId) else {
            val libraries = try { api.getCatalogLibrariesLegacy().catalogResponse() } catch (e: Exception) { return failed(e, CatalogImportStage.LEGACY) }
            if (!libraries.isSuccessful) return failed(libraries, CatalogImportStage.LEGACY)
            libraries.body()?.map { it.id } ?: return GrimmoryCatalogBatch(report = problem(CatalogFailureKind.INVALID_PAGE, CatalogImportStage.LEGACY))
        }
        val books = mutableListOf<BookSummaryDto>()
        var report = CatalogImportReport()
        for (id in ids.distinct()) {
            try {
                val response = api.getCatalogBooksLegacy(id).catalogResponse()
                if (!response.isSuccessful) {
                    report = report.merge(failed(response, CatalogImportStage.LEGACY).report)
                    continue
                }
                val decoded = decode(response.body() as? JsonArray ?: throw SerializationException(), LegacyBookloreBookDto.serializer(), id) { it.libraryId }
                report = report.merge(decoded.second)
                books += decoded.first.map { it.toBookSummaryDto(id) }
            } catch (e: Exception) {
                report = report.merge(failed(e, CatalogImportStage.LEGACY).report)
            }
        }
        val unique = books.distinctBy { it.id }
        return GrimmoryCatalogBatch(unique, report.copy(acceptedCount = unique.size))
    }

    private fun <T> decode(
        elements: JsonArray,
        serializer: DeserializationStrategy<T>,
        libraryId: String?,
        library: (T) -> String?,
    ): Pair<List<T>, CatalogImportReport> {
        val books = mutableListOf<T>()
        var report = CatalogImportReport()
        for (element in elements) {
            val id = (element as? JsonObject)?.get("id")
            val primitive = id as? JsonPrimitive
            val text = primitive?.contentOrNull
            val reason = when {
                id == null || id == JsonNull || text?.isBlank() == true || text == "null" -> CatalogRejectionReason.MISSING_ID
                primitive == null || (!primitive.isString && primitive.longOrNull?.let { it > 0 } != true) || text?.toLongOrNull()?.let { it <= 0 } == true -> CatalogRejectionReason.INVALID_ID
                else -> null
            }
            if (reason != null) {
                report = report.rejecting(reason)
                continue
            }
            try {
                val book = json.decodeFromJsonElement(serializer, element)
                if (libraryId != null && library(book)?.let { it != libraryId } == true) {
                    report = report.rejecting(CatalogRejectionReason.WRONG_LIBRARY)
                } else books += book
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                report = report.rejecting(CatalogRejectionReason.INVALID_RECORD)
            }
        }
        return books to report
    }

    private fun failed(response: Response<*>, stage: CatalogImportStage, page: Int? = null): GrimmoryCatalogBatch =
        GrimmoryCatalogBatch(report = problem(
            if (response.code() in listOf(401, 403)) CatalogFailureKind.ACCESS_DENIED else CatalogFailureKind.HTTP,
            stage, page, response.code(),
        ))

    private fun failed(error: Exception, stage: CatalogImportStage, page: Int? = null): GrimmoryCatalogBatch {
        if (error is CancellationException) throw error
        return GrimmoryCatalogBatch(report = problem(
            if (error is IOException) CatalogFailureKind.NETWORK else CatalogFailureKind.INVALID_PAGE, stage, page,
        ))
    }

    private fun problem(kind: CatalogFailureKind, stage: CatalogImportStage, page: Int? = null, http: Int? = null): CatalogImportReport =
        CatalogImportReport(failures = listOf(CatalogFailure(kind, stage, page, http)))
}

internal fun LegacyBookloreBookDto.toBookSummaryDto(fallbackLibraryId: String?): BookSummaryDto = BookSummaryDto(
    id = id, title = listOfNotNull(title, metadata?.title, name).firstOrNull { it.isNotBlank() } ?: "Untitled",
    authors = metadata?.authors, thumbnailUrl = metadata?.thumbnailUrl, readStatus = readStatus,
    seriesName = metadata?.seriesName, seriesNumber = metadata?.seriesNumber, libraryId = libraryId ?: fallbackLibraryId,
    addedOn = addedOn, lastReadTime = lastReadTime, readProgress = readProgress,
    primaryFileType = primaryFile?.bookType, primaryFile = primaryFile, alternativeFormats = alternativeFormats,
    coverUpdatedOn = metadata?.coverUpdatedOn, audiobookCoverUpdatedOn = metadata?.audiobookCoverUpdatedOn,
)
