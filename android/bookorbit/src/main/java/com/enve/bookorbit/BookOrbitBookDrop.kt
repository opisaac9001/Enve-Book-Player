package com.enve.bookorbit

import com.enve.bookorbit.api.BookOrbitApi
import com.enve.bookorbit.dto.BookOrbitBookDockApplyFetchedDto
import com.enve.bookorbit.dto.BookOrbitBookDockFileDto
import com.enve.bookorbit.dto.BookOrbitBookDockFilesPageDto
import com.enve.bookorbit.dto.BookOrbitBookDockFinalizeDto
import com.enve.bookorbit.dto.BookOrbitBookDockMetadataDto
import com.enve.bookorbit.dto.BookOrbitBookDockSelectionRequest
import com.enve.bookorbit.dto.BookOrbitBookDockSummaryDto
import com.enve.bookorbit.dto.BookOrbitBookDockUpdateRequest
import com.enve.bookorbit.dto.BookOrbitLibraryDto
import com.enve.core.data.util.runSuspendCatching
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.RequestBody
import okio.BufferedSink
import okio.source
import java.io.InputStream
import javax.inject.Inject
import javax.inject.Singleton

data class BookOrbitDockAccess(
    val canView: Boolean,
    val canFinalize: Boolean,
    val managesAll: Boolean,
)

data class BookOrbitDockQuery(
    val page: Int = 1,
    val status: String? = null,
    val search: String? = null,
    val pageSize: Int = BookOrbitBookDrop.PAGE_SIZE,
)

class BookOrbitDockUpload(
    val fileName: String,
    val length: Long?,
    val open: () -> InputStream,
)

private val metadataJson = Json {
    ignoreUnknownKeys = true
    coerceInputValues = true
}

private val EDITABLE_METADATA_KEYS = setOf(
    "title", "subtitle", "authors", "narrators", "description", "publisher", "publishedYear",
    "language", "isbn13", "seriesName", "seriesIndex", "genres",
)

fun bookOrbitDockMetadata(raw: JsonObject?): BookOrbitBookDockMetadataDto? =
    raw?.takeIf { it.isNotEmpty() }?.let { runCatching { metadataJson.decodeFromJsonElement<BookOrbitBookDockMetadataDto>(it) }.getOrNull() }

fun bookOrbitEffectiveDockMetadata(file: BookOrbitBookDockFileDto): BookOrbitBookDockMetadataDto =
    bookOrbitDockMetadata(
        JsonObject(file.embeddedMetadata.orEmpty() + file.fetchedMetadata.orEmpty() + file.selectedMetadata.orEmpty()),
    ) ?: BookOrbitBookDockMetadataDto()

internal fun bookOrbitSelectedMetadata(file: BookOrbitBookDockFileDto, edits: BookOrbitBookDockMetadataDto): JsonObject {
    val selected = file.selectedMetadata.orEmpty()
    val inherited = file.embeddedMetadata.orEmpty() + file.fetchedMetadata.orEmpty()
    return buildJsonObject {
        selected.forEach { (key, value) -> if (key !in EDITABLE_METADATA_KEYS) put(key, value) }
        fun field(key: String, value: JsonElement?) {
            if (value != null) put(key, value)
            else if (key in selected || inherited[key].let { it != null && it !is JsonNull }) put(key, JsonNull)
        }
        fun text(key: String, value: String?) =
            field(key, value?.trim()?.takeIf { it.isNotEmpty() }?.let(::JsonPrimitive))
        fun list(key: String, values: List<String>) {
            val cleaned = values.map(String::trim).filter(String::isNotEmpty).distinct()
            field(key, cleaned.takeIf { it.isNotEmpty() }?.let { names -> JsonArray(names.map(::JsonPrimitive)) })
        }
        text("title", edits.title)
        text("subtitle", edits.subtitle)
        list("authors", edits.authors)
        list("narrators", edits.narrators)
        text("description", edits.description)
        text("publisher", edits.publisher)
        field("publishedYear", edits.publishedYear?.let(::JsonPrimitive))
        text("language", edits.language)
        text("isbn13", edits.isbn13?.filter(Char::isLetterOrDigit))
        text("seriesName", edits.seriesName)
        text("seriesIndex", edits.seriesIndex)
        list("genres", edits.genres)
    }
}

@Singleton
class BookOrbitBookDrop @Inject constructor(
    private val api: BookOrbitApi,
) {
    suspend fun access(): Result<BookOrbitDockAccess> = runSuspendCatching {
        val user = bookOrbitBody("BookOrbit account lookup failed", api.me())
        val canView = user.isSuperuser || PERMISSION_ACCESS in user.permissions
        BookOrbitDockAccess(
            canView = canView,
            canFinalize = canView && (user.isSuperuser || PERMISSION_UPLOAD in user.permissions),
            managesAll = user.isSuperuser || PERMISSION_MANAGE in user.permissions,
        )
    }

    suspend fun files(query: BookOrbitDockQuery): Result<BookOrbitBookDockFilesPageDto> = runSuspendCatching {
        bookOrbitBody(
            "BookOrbit Book Drop list failed",
            api.bookDockFiles(
                page = query.page.coerceAtLeast(1),
                limit = query.pageSize.coerceIn(1, MAX_PAGE_SIZE),
                status = query.status?.takeIf { it in LIST_STATUSES },
                search = query.search?.trim()?.take(MAX_SEARCH_LENGTH)?.takeIf { it.isNotEmpty() },
            ),
        )
    }

    suspend fun summary(): Result<BookOrbitBookDockSummaryDto> = runSuspendCatching {
        bookOrbitBody("BookOrbit Book Drop summary failed", api.bookDockSummary())
    }

    suspend fun file(fileId: Int): Result<BookOrbitBookDockFileDto> = runSuspendCatching {
        bookOrbitBody("BookOrbit Book Drop file failed", api.bookDockFile(fileId))
    }

    suspend fun libraries(): Result<List<BookOrbitLibraryDto>> = runSuspendCatching {
        bookOrbitBody("BookOrbit libraries failed", api.libraries())
    }

    suspend fun upload(upload: BookOrbitDockUpload, libraryId: Int? = null): Result<BookOrbitBookDockFileDto> =
        runSuspendCatching {
            val body = object : RequestBody() {
                override fun contentType(): MediaType = OCTET_STREAM
                override fun contentLength(): Long = upload.length ?: -1L
                override fun writeTo(sink: BufferedSink) {
                    upload.open().use { input -> sink.writeAll(input.source()) }
                }
            }
            val part = MultipartBody.Part.createFormData("file", upload.fileName, body)
            bookOrbitBody("BookOrbit Book Drop upload failed", api.uploadBookDockFile(part, libraryId))
        }

    suspend fun update(
        file: BookOrbitBookDockFileDto,
        edits: BookOrbitBookDockMetadataDto?,
        targetLibraryId: Int?,
        targetFolderId: Int?,
    ): Result<BookOrbitBookDockFileDto> = runSuspendCatching {
        val retargeted = targetLibraryId != null && targetFolderId != null &&
            (targetLibraryId != file.targetLibraryId || targetFolderId != file.targetFolderId)
        val request = BookOrbitBookDockUpdateRequest(
            selectedMetadata = edits?.let { bookOrbitSelectedMetadata(file, it) },
            targetLibraryId = targetLibraryId.takeIf { retargeted },
            targetFolderId = targetFolderId.takeIf { retargeted },
        )
        bookOrbitBody("BookOrbit Book Drop update failed", api.updateBookDockFile(file.id, request))
    }

    suspend fun applyFetched(fileIds: List<Int>): Result<BookOrbitBookDockApplyFetchedDto> = runSuspendCatching {
        bookOrbitBody(
            "BookOrbit Book Drop metadata apply failed",
            api.applyFetchedBookDockMetadata(BookOrbitBookDockSelectionRequest(selection(fileIds))),
        )
    }

    suspend fun finalize(fileIds: List<Int>): Result<BookOrbitBookDockFinalizeDto> = runSuspendCatching {
        bookOrbitBody(
            "BookOrbit Book Drop approval failed",
            api.finalizeBookDockFiles(BookOrbitBookDockSelectionRequest(selection(fileIds))),
        )
    }

    suspend fun discard(fileIds: List<Int>): Result<Unit> = runSuspendCatching {
        val response = api.discardBookDockFiles(BookOrbitBookDockSelectionRequest(selection(fileIds)))
        if (!response.isSuccessful) throw bookOrbitFailure("BookOrbit Book Drop discard failed", response)
    }

    private fun selection(fileIds: List<Int>): List<Int> =
        fileIds.distinct().also { require(it.isNotEmpty()) { "Select at least one Book Drop file" } }

    companion object {
        const val PAGE_SIZE = 30
        private const val MAX_PAGE_SIZE = 100
        private const val MAX_SEARCH_LENGTH = 500
        private const val PERMISSION_ACCESS = "book_dock_access"
        private const val PERMISSION_UPLOAD = "library_upload"
        private const val PERMISSION_MANAGE = "manage_book_dock"
        private val LIST_STATUSES = setOf("pending", "ready", "error")
        private val OCTET_STREAM = "application/octet-stream".toMediaType()
    }
}
