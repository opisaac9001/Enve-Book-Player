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

    private val urlByPage = mutableMapOf<Int, String>()

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, BookSummary> {
        val page = params.key ?: 0
        val url = urlByPage[page]
            ?: repo.getRootCatalogUrl(this.params.connectionId)
            ?: return LoadResult.Error(IllegalStateException("No OPDS root URL configured"))
        return repo.getPage(this.params.connectionId, url).fold(
            onSuccess = { result ->
                result.totalResults?.let { total -> this.params.onTotalCountChanged?.invoke(total) }
                val nextKey = result.nextUrl?.let { nextUrl ->
                    urlByPage[page + 1] = nextUrl
                    page + 1
                }
                LoadResult.Page(
                    data = result.items,
                    prevKey = if (page == 0) null else page - 1,
                    nextKey = nextKey,
                )
            },
            onFailure = { LoadResult.Error(it) },
        )
    }

    override fun getRefreshKey(state: PagingState<Int, BookSummary>): Int? = null
}
