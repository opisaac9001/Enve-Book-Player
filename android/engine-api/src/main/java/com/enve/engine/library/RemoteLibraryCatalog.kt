package com.enve.engine.library

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.RemoteCatalogRequest
import com.enve.core.data.provider.RemoteCatalogFilterOptions

data class RemoteLibraryRequest(
    val catalog: RemoteCatalogRequest = RemoteCatalogRequest(),
    val source: BookSource? = null,
    val libraryId: String? = null,
    val connectionId: String? = null,
    val excludedLibraryIds: Set<String> = emptySet(),
)

data class RemoteLibraryPage(
    val books: List<Book> = emptyList(),
    val nextCursors: Map<String, String> = emptyMap(),
    val offline: Boolean = false,
    val error: String? = null,
)

data class RemoteLibraryFilterOptions(
    val options: RemoteCatalogFilterOptions = RemoteCatalogFilterOptions(),
    val error: String? = null,
)
