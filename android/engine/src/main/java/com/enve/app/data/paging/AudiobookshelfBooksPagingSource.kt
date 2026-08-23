package com.enve.app.data.paging

import androidx.paging.PagingSource
import androidx.paging.PagingState
import com.enve.core.data.model.BookSummary
import com.enve.core.data.remote.ConnectionScope
import com.enve.audiobookshelf.AudiobookshelfRepository
import kotlinx.coroutines.withContext

class AudiobookshelfBooksPagingSource(
    private val repo: AudiobookshelfRepository,
    private val params: Params,

    private val onTotalCount: ((Int) -> Unit)? = null,
) : PagingSource<Int, BookSummary>() {

    data class Params(
        val connectionId: String,
        val libraryId: String,
        val sort: String = "media.metadata.title",
        val dir: String = "asc",
    )

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, BookSummary> {
        val page = params.key ?: 0
        return withContext(ConnectionScope.asContextElement(this.params.connectionId)) {
            repo.getBooksPage(
                connectionId = this@AudiobookshelfBooksPagingSource.params.connectionId,
                libraryId = this@AudiobookshelfBooksPagingSource.params.libraryId,
                page = page,
                size = params.loadSize,
                sort = this@AudiobookshelfBooksPagingSource.params.sort,
                dir = this@AudiobookshelfBooksPagingSource.params.dir,
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
