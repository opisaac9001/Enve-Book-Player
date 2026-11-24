package com.enve.hearth.bookorbit

enum class BookOrbitPageFailure { FIRST_PAGE, REFRESH, NEXT_PAGE }

data class BookOrbitPagedList<T>(
    val firstPage: Int,
    val items: List<T> = emptyList(),
    val total: Int? = null,
    val loadedPages: Int = 0,
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    val failure: BookOrbitPageFailure? = null,
    val exhausted: Boolean = false,
    val generation: Int = 0,
) {
    val nextPage: Int get() = firstPage + loadedPages

    val hasMore: Boolean
        get() = loadedPages > 0 && !exhausted && (total == null || items.size < total)

    val canLoadMore: Boolean get() = hasMore && !loading && !loadingMore

    val showsFirstLoad: Boolean get() = loading && loadedPages == 0

    fun restart(): BookOrbitPagedList<T> =
        BookOrbitPagedList(firstPage = firstPage, loading = true, generation = generation + 1)

    fun cleared(): BookOrbitPagedList<T> =
        BookOrbitPagedList(firstPage = firstPage, generation = generation + 1)

    fun refresh(): BookOrbitPagedList<T> =
        copy(loading = true, loadingMore = false, failure = null, generation = generation + 1)

    fun beginNextPage(): BookOrbitPagedList<T>? =
        if (canLoadMore) copy(loadingMore = true, failure = null) else null

    fun <K> receive(
        generation: Int,
        page: Int,
        pageItems: List<T>,
        total: Int?,
        key: (T) -> K,
    ): BookOrbitPagedList<T> = when {
        generation != this.generation -> this
        page == firstPage -> copy(
            items = pageItems.distinctBy(key),
            total = total,
            loadedPages = 1,
            loading = false,
            loadingMore = false,
            failure = null,
            exhausted = pageItems.isEmpty(),
        )
        page == nextPage && loadingMore -> copy(
            items = (items + pageItems).distinctBy(key),
            total = total ?: this.total,
            loadedPages = loadedPages + 1,
            loadingMore = false,
            failure = null,
            exhausted = pageItems.isEmpty(),
        )
        else -> this
    }

    fun fail(generation: Int, page: Int): BookOrbitPagedList<T> = when {
        generation != this.generation -> this
        page == firstPage -> copy(
            loading = false,
            failure = if (loadedPages == 0) BookOrbitPageFailure.FIRST_PAGE else BookOrbitPageFailure.REFRESH,
        )
        page == nextPage && loadingMore -> copy(loadingMore = false, failure = BookOrbitPageFailure.NEXT_PAGE)
        else -> this
    }

    fun removing(predicate: (T) -> Boolean): BookOrbitPagedList<T> {
        val kept = items.filterNot(predicate)
        val removed = items.size - kept.size
        return if (removed == 0) this else copy(items = kept, total = total?.let { (it - removed).coerceAtLeast(0) })
    }

    fun replacing(predicate: (T) -> Boolean, replacement: T): BookOrbitPagedList<T> =
        copy(items = items.map { if (predicate(it)) replacement else it })
}
