package com.enve.app.data.paging

import androidx.paging.PagingSource
import androidx.paging.PagingState
import com.enve.bookorbit.BookOrbitRepository
import com.enve.core.data.model.Book
import com.enve.core.data.remote.ConnectionScope
import kotlinx.coroutines.withContext

class BookOrbitBooksPagingSource(
    private val repository: BookOrbitRepository,
    private val params: Params,
) : PagingSource<Int, Book>() {

    data class Params(
        val connectionId: String,
        val libraryId: String?,
    )

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, Book> {
        val page = params.key ?: 0
        return withContext(ConnectionScope.asContextElement(this@BookOrbitBooksPagingSource.params.connectionId)) {
            repository.getBooks(
                libraryId = this@BookOrbitBooksPagingSource.params.libraryId,
                page = page,
                size = params.loadSize,
            ).fold(
                onSuccess = { books ->
                    LoadResult.Page(
                        data = books,
                        prevKey = if (page == 0) null else page - 1,
                        nextKey = if (books.size == params.loadSize) page + 1 else null,
                    )
                },
                onFailure = { LoadResult.Error(it) },
            )
        }
    }

    override fun getRefreshKey(state: PagingState<Int, Book>): Int? =
        state.anchorPosition?.let { anchor ->
            val closest = state.closestPageToPosition(anchor) ?: return null
            closest.prevKey?.plus(1) ?: closest.nextKey?.minus(1)
        }
}
