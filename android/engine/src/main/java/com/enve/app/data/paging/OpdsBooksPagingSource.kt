package com.enve.app.data.paging

import androidx.paging.PagingSource
import androidx.paging.PagingState
import com.enve.core.data.model.BookSummary
import com.enve.app.data.repository.OpdsRepository

class OpdsBooksPagingSource(
    private val repo: OpdsRepository,
    private val params: Params,
) : PagingSource<Int, BookSummary>() {

    data class Params(
        val connectionId: String,
        val onTotalCountChanged: ((Int) -> Unit)? = null,
    )

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, BookSummary> {
        val page = params.key ?: 0
        return repo.getDocumentPage(this.params.connectionId, page).fold(
            onSuccess = { result ->
                result.totalResults?.let { total -> this.params.onTotalCountChanged?.invoke(total) }
                LoadResult.Page(
                    data = result.items,
                    prevKey = if (page == 0) null else page - 1,
                    nextKey = (page + 1).takeIf { result.hasMore },
                )
            },
            onFailure = { LoadResult.Error(it) },
        )
    }

    override fun getRefreshKey(state: PagingState<Int, BookSummary>): Int? = null
}
