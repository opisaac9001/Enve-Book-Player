package com.enve.app.data.paging

import androidx.paging.PagingSource
import androidx.paging.PagingState
import com.enve.core.data.model.BrowseGroup
import com.enve.app.data.repository.GrimmoryAppRepository

class GrimmorySeriesPagingSource(
    private val repo: GrimmoryAppRepository,
    private val params: Params,
) : PagingSource<Int, BrowseGroup>() {

    data class Params(
        val connectionId: String,
        val libraryId: Long? = null,
        val sort: String = "name",
        val dir: String = "asc",
        val search: String? = null,
        val status: String? = null,
    )

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, BrowseGroup> {
        val page = params.key ?: 0
        return repo.getSeriesPage(
            connectionId = this.params.connectionId,
            libraryId = this.params.libraryId,
            page = page,
            size = params.loadSize,
            sort = this.params.sort,
            dir = this.params.dir,
            search = this.params.search,
            status = this.params.status,
        ).fold(
            onSuccess = { result ->
                LoadResult.Page(
                    data = result.items,
                    prevKey = if (page == 0) null else page - 1,
                    nextKey = if (result.hasNext) page + 1 else null,
                )
            },
            onFailure = { LoadResult.Error(it) },
        )
    }

    override fun getRefreshKey(state: PagingState<Int, BrowseGroup>): Int? = null
}
