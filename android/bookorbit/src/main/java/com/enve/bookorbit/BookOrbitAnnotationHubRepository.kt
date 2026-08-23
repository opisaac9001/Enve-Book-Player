package com.enve.bookorbit

import com.enve.bookorbit.api.BookOrbitApi
import com.enve.bookorbit.dto.BookOrbitAnnotationBookFacetDto
import com.enve.bookorbit.dto.BookOrbitAnnotationBulkRequest
import com.enve.bookorbit.dto.BookOrbitAnnotationHubPageDto
import javax.inject.Inject
import javax.inject.Singleton
import retrofit2.Response

data class BookOrbitAnnotationHubFilter(
    val page: Int = 1,
    val pageSize: Int = 40,
    val trashed: Boolean = false,
    val search: String? = null,
    val bookId: Int? = null,
    val colors: List<String> = emptyList(),
    val origins: List<String> = emptyList(),
    val notesOnly: Boolean = false,
)

data class BookOrbitAnnotationExport(
    val filename: String,
    val content: String,
)

@Singleton
class BookOrbitAnnotationHubRepository @Inject constructor(
    private val api: BookOrbitApi,
) {
    suspend fun list(filter: BookOrbitAnnotationHubFilter): Result<BookOrbitAnnotationHubPageDto?> = runCatching {
        val response = api.annotationHub(
            page = filter.page.coerceAtLeast(1),
            pageSize = filter.pageSize.coerceIn(1, 100),
            status = filter.status(),
            search = filter.search?.trim()?.takeIf { it.isNotEmpty() },
            bookId = filter.bookId,
            colors = filter.colors.joinToCsv(),
            origins = filter.origins.joinToCsv(),
            hasNote = true.takeIf { filter.notesOnly },
        )
        response.unwrap("BookOrbit highlights failed")
    }

    suspend fun books(trashed: Boolean, query: String?): Result<List<BookOrbitAnnotationBookFacetDto>> = runCatching {
        val response = api.annotationHubBooks(
            status = if (trashed) STATUS_TRASHED else STATUS_ACTIVE,
            query = query?.trim()?.takeIf { it.isNotEmpty() },
            limit = BOOK_FACET_LIMIT,
        )
        response.unwrap("BookOrbit highlight books failed").orEmpty()
    }

    suspend fun trash(ids: List<Int>): Result<Int> = bulk(ids, "trash")

    suspend fun restoreAll(ids: List<Int>): Result<Int> = bulk(ids, "restore")

    suspend fun restore(annotationId: Int): Result<Unit> = runCatching {
        val response = api.restoreHubAnnotation(annotationId)
        if (!response.isSuccessful) error("BookOrbit highlight restore failed: HTTP ${response.code()}")
    }

    suspend fun purge(annotationId: Int): Result<Unit> = runCatching {
        val response = api.purgeHubAnnotation(annotationId)
        if (!response.isSuccessful && response.code() != 404) {
            error("BookOrbit highlight delete failed: HTTP ${response.code()}")
        }
    }

    suspend fun export(
        filter: BookOrbitAnnotationHubFilter,
        format: String,
    ): Result<BookOrbitAnnotationExport?> = runCatching {
        val response = api.exportAnnotations(
            format = format,
            status = filter.status(),
            search = filter.search?.trim()?.takeIf { it.isNotEmpty() },
            bookId = filter.bookId,
            colors = filter.colors.joinToCsv(),
            origins = filter.origins.joinToCsv(),
            hasNote = true.takeIf { filter.notesOnly },
        )
        if (response.code() == 404) return@runCatching null
        if (!response.isSuccessful) error("BookOrbit highlight export failed: HTTP ${response.code()}")
        val body = response.body() ?: return@runCatching null
        BookOrbitAnnotationExport(
            filename = response.headers()["Content-Disposition"].toFilename(format),
            content = body.string(),
        )
    }

    private suspend fun bulk(ids: List<Int>, action: String): Result<Int> = runCatching {
        val distinct = ids.distinct()
        if (distinct.isEmpty()) return@runCatching 0
        var affected = 0
        for (chunk in distinct.chunked(BULK_CHUNK)) {
            val response = api.annotationHubBulk(BookOrbitAnnotationBulkRequest(ids = chunk, action = action))
            if (!response.isSuccessful) error("BookOrbit highlight update failed: HTTP ${response.code()}")
            affected += response.body()?.affected ?: 0
        }
        affected
    }

    private fun <T> Response<T>.unwrap(message: String): T? {
        if (code() == 404) return null
        if (!isSuccessful) error("$message: HTTP ${code()}")
        return body()
    }

    private fun BookOrbitAnnotationHubFilter.status(): String = if (trashed) STATUS_TRASHED else STATUS_ACTIVE

    private fun List<String>.joinToCsv(): String? =
        filter { it.isNotBlank() }.distinct().takeIf { it.isNotEmpty() }?.joinToString(",")

    private fun String?.toFilename(format: String): String {
        val match = this?.let { Regex("filename=\"?([^\";]+)\"?").find(it)?.groupValues?.getOrNull(1) }
        return match?.takeIf { it.isNotBlank() } ?: "bookorbit-highlights.$format"
    }

    private companion object {
        const val STATUS_ACTIVE = "active"
        const val STATUS_TRASHED = "trashed"
        const val BOOK_FACET_LIMIT = 50
        const val BULK_CHUNK = 500
    }
}
