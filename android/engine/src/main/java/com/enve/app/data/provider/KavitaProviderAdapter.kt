package com.enve.app.data.provider

import com.enve.app.data.repository.GrimmoryRepository
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.sync.SyncCapability
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class KavitaProviderAdapter @Inject constructor(
    private val repository: GrimmoryRepository,
) : ProviderAdapter {
    override val source: BookSource = BookSource.KAVITA
    override val syncCapability: SyncCapability = SyncCapability.READ_WRITE

    override suspend fun getLibraries(): Result<List<Library>> =
        repository.getLibrariesForSource(source)

    override suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): Result<List<Book>> = repository.getBooksForSource(source, libraryId, page, size, sort, dir)

    override suspend fun getContinueListening(): Result<List<Book>> =
        Result.success(emptyList())

    override suspend fun getContinueReading(): Result<List<Book>> =
        repository.getContinueReadingForSource(source)

    override suspend fun getRecentlyAdded(): Result<List<Book>> =
        repository.getRecentlyAddedForSource(source)

    override suspend fun getEbookDownloadUrl(bookId: String): String? = null

    override fun invalidateCaches() {
        repository.invalidateListCaches()
    }
}
