package com.enve.bookorbit

import com.enve.bookorbit.api.BookOrbitApi
import com.enve.bookorbit.dto.BookOrbitBookCardDto
import com.enve.bookorbit.dto.BookOrbitPaginationRequest
import com.enve.bookorbit.dto.BookOrbitSmartScopeBooksRequest
import com.enve.bookorbit.dto.BookOrbitSmartScopeDto
import com.enve.core.data.model.Book
import com.enve.core.data.util.runSuspendCatching
import javax.inject.Inject
import javax.inject.Singleton

data class BookOrbitSmartScopeBooks(
    val books: List<Book>,
    val total: Int,
    val page: Int,
    val size: Int,
)

@Singleton
class BookOrbitSmartScopes(
    private val api: BookOrbitApi,
    private val toBook: (BookOrbitBookCardDto) -> Book,
) {
    @Inject
    constructor(api: BookOrbitApi, repository: BookOrbitRepository) : this(api, repository::book)

    suspend fun list(): Result<List<BookOrbitSmartScopeDto>> = runSuspendCatching {
        bookOrbitBody("BookOrbit smart scopes failed", api.smartScopes())
            .sortedWith(compareBy({ it.displayOrder }, { it.name.lowercase() }, { it.id }))
    }

    suspend fun books(
        scopeId: Int,
        page: Int,
        search: String? = null,
        size: Int = PAGE_SIZE,
    ): Result<BookOrbitSmartScopeBooks> = runSuspendCatching {
        val request = BookOrbitSmartScopeBooksRequest(
            pagination = BookOrbitPaginationRequest(page = page.coerceAtLeast(0), size = size.coerceIn(1, MAX_PAGE_SIZE)),
            q = search?.trim()?.take(MAX_SEARCH_LENGTH)?.takeIf { it.isNotEmpty() },
        )
        val body = bookOrbitBody("BookOrbit smart scope books failed", api.smartScopeBooks(scopeId, request))
        BookOrbitSmartScopeBooks(
            books = body.items.map(toBook),
            total = body.total,
            page = body.page,
            size = body.size.takeIf { it > 0 } ?: request.pagination.size,
        )
    }

    companion object {
        const val PAGE_SIZE = 50
        private const val MAX_PAGE_SIZE = 200
        private const val MAX_SEARCH_LENGTH = 200
    }
}
