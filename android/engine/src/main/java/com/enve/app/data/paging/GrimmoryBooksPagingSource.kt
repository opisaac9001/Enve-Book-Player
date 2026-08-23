package com.enve.app.data.paging

import androidx.paging.PagingSource
import androidx.paging.PagingState
import com.enve.core.data.model.BookSummary
import com.enve.core.data.model.ReadStatus
import com.enve.app.data.repository.GrimmoryAppRepository

class GrimmoryBooksPagingSource(
    private val repo: GrimmoryAppRepository,
    private val params: Params,
) : PagingSource<Int, BookSummary>() {

    data class Params(
        val connectionId: String,
        val libraryId: Long? = null,
        val shelfId: Long? = null,
        val sort: String = "addedOn",
        val dir: String = "desc",
        val status: ReadStatus? = null,
        val search: String? = null,
        val fileType: String? = null,
        val authors: String? = null,
        val language: String? = null,
        val minRating: Int? = null,
        val maxRating: Int? = null,
    )

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, BookSummary> {
        val page = params.key ?: 0
        return repo.getBooksPage(
            connectionId = this.params.connectionId,
            libraryId = this.params.libraryId,
            shelfId = this.params.shelfId,
            page = page,
            size = params.loadSize,
            sort = this.params.sort,
            dir = this.params.dir,
            status = this.params.status,
            search = this.params.search,
            fileType = this.params.fileType,
            authors = this.params.authors,
            language = this.params.language,
            minRating = this.params.minRating,
            maxRating = this.params.maxRating,
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

    override fun getRefreshKey(state: PagingState<Int, BookSummary>): Int? {
        return state.anchorPosition?.let { anchor ->
            val closest = state.closestPageToPosition(anchor) ?: return null
            closest.prevKey?.plus(1) ?: closest.nextKey?.minus(1)
        }
    }
}
