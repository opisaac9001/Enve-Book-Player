package com.enve.core.data.provider

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource

enum class RemoteCatalogSort { TITLE, RECENTLY_ADDED }

data class RemoteCatalogRequest(
    val search: String = "",
    val mediaType: AppMediaType? = null,
    val sort: RemoteCatalogSort = RemoteCatalogSort.TITLE,
    val genres: Set<String> = emptySet(),
    val languages: Set<String> = emptySet(),
)

data class RemoteCatalogPage(val books: List<Book>, val nextCursor: String?)

data class RemoteCatalogFilterOptions(
    val genres: List<String> = emptyList(),
    val languages: List<String> = emptyList(),
    val hasMore: Boolean = false,
)

interface RemoteCatalogBrowsingProvider {
    val source: BookSource
    suspend fun fetchRemoteCatalogDetail(book: Book): Book
    suspend fun fetchRemoteCatalogPage(libraryId: String, request: RemoteCatalogRequest, cursor: String?, limit: Int = 50): RemoteCatalogPage
    suspend fun fetchRemoteCatalogFilterOptions(libraryId: String, mediaType: AppMediaType?, search: String): RemoteCatalogFilterOptions
}
