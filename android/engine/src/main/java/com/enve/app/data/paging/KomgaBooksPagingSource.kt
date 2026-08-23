package com.enve.app.data.paging

import androidx.paging.PagingSource
import androidx.paging.PagingState
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.BookSummary
import com.enve.core.data.remote.ConnectionScope
import com.enve.komga.KomgaRepository
import kotlinx.coroutines.withContext

class KomgaBooksPagingSource(
    private val repo: KomgaRepository,
    private val connectionRegistry: ConnectionRegistry,
    private val params: Params,

    private val onTotalCount: ((Int) -> Unit)? = null,
) : PagingSource<Int, BookSummary>() {

    data class Params(
        val connectionId: String,
        val libraryId: String? = null,
        val sort: String = "metadata.title",
        val dir: String = "asc",
        val readStatus: List<String>? = null,
        val search: String? = null,
    )

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, BookSummary> {
        val page = params.key ?: 0

        return withContext(ConnectionScope.asContextElement(this.params.connectionId)) {
            repo.getBooksPage(
                connectionId = this@KomgaBooksPagingSource.params.connectionId,
                libraryId = this@KomgaBooksPagingSource.params.libraryId,
                page = page,
                size = params.loadSize,
                sort = this@KomgaBooksPagingSource.params.sort,
                dir = this@KomgaBooksPagingSource.params.dir,
                readStatus = this@KomgaBooksPagingSource.params.readStatus,
                search = this@KomgaBooksPagingSource.params.search,
            ).fold(
                onSuccess = { result ->
                    if (page == 0) onTotalCount?.invoke(result.totalElements.toInt())
                    LoadResult.Page(
                        data = result.items,
                        prevKey = if (page == 0) null else page - 1,
                        nextKey = if (result.hasNext) page + 1 else null,
                    )
                },
                onFailure = { LoadResult.Error(it) },
            )
        }
    }

    override fun getRefreshKey(state: PagingState<Int, BookSummary>): Int? = null
}
