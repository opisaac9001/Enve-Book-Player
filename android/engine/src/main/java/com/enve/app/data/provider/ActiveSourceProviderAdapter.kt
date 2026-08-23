package com.enve.app.data.provider

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.model.Shelf
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.sync.SyncCapability
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ActiveSourceProviderAdapter @Inject constructor(
    private val repository: GrimmoryRepository,
) : ProviderAdapter {

    override val source: BookSource = BookSource.GRIMMORY
    override val syncCapability: SyncCapability = SyncCapability.FULL

    override suspend fun getLibraries(): Result<List<Library>> = repository.getLibraries()

    override suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): Result<List<Book>> = repository.getBooks(
        libraryId = libraryId,
        page = page,
        size = size,
        sort = sort,
        dir = dir,
    )

    override suspend fun getContinueListening(): Result<List<Book>> = repository.getContinueListening()

    override suspend fun getContinueReading(): Result<List<Book>> = repository.getContinueReading()

    override suspend fun getRecentlyAdded(): Result<List<Book>> = repository.getRecentlyAdded()

    override suspend fun getEbookDownloadUrl(bookId: String): String? = repository.getEbookDownloadUrl(bookId)

    override fun invalidateCaches() {
        repository.invalidateListCaches()
    }

    override suspend fun getSeries(): Result<List<com.enve.core.data.remote.dto.SeriesSummaryDto>> =
        repository.getSeries()

    override suspend fun getAuthors(): Result<List<com.enve.core.data.remote.dto.AuthorSummaryDto>> =
        repository.getAuthors()

    override suspend fun getShelves(): Result<List<Shelf>> =
        repository.getShelves()

    override suspend fun getShelfBooks(shelfId: String): Result<List<Book>> =
        repository.getShelfBooks(shelfId)
}
