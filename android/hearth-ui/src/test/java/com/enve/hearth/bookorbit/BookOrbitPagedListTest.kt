package com.enve.hearth.bookorbit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class BookOrbitPagedListTest {
    private fun started(firstPage: Int = 0) = BookOrbitPagedList<Int>(firstPage = firstPage).restart()

    private fun BookOrbitPagedList<Int>.loaded(page: Int, items: List<Int>, total: Int?) =
        receive(generation, page, items, total) { it }

    @Test
    fun firstPageKeepsExactServerTotalAndOffersMore() {
        val list = started().loaded(page = 0, items = (1..50).toList(), total = 137)

        assertEquals(137, list.total)
        assertEquals(50, list.items.size)
        assertEquals(1, list.nextPage)
        assertTrue(list.hasMore)
        assertFalse(list.loading)
    }

    @Test
    fun subsequentPagesAppendUntilTheTotalIsReached() {
        var list = started().loaded(0, (1..50).toList(), 120)
        list = list.beginNextPage()!!.loaded(1, (51..100).toList(), 120)
        assertEquals(2, list.nextPage)
        assertTrue(list.hasMore)

        list = list.beginNextPage()!!.loaded(2, (101..120).toList(), 120)
        assertEquals(120, list.items.size)
        assertFalse(list.hasMore)
        assertNull(list.beginNextPage())
    }

    @Test
    fun oneBasedListsRequestPageTwoAfterTheFirst() {
        val list = started(firstPage = 1).loaded(1, listOf(1, 2), 5)

        assertEquals(2, list.nextPage)
        assertEquals(listOf(1, 2, 3), list.beginNextPage()!!.loaded(2, listOf(3), 5).items)
    }

    @Test
    fun failedNextPageKeepsItemsAndCanBeRetriedWithoutExhaustingTheList() {
        val loaded = started().loaded(0, (1..50).toList(), 90)
        val loadingMore = loaded.beginNextPage()!!
        val failed = loadingMore.fail(loadingMore.generation, page = 1)

        assertEquals(BookOrbitPageFailure.NEXT_PAGE, failed.failure)
        assertEquals(50, failed.items.size)
        assertTrue(failed.hasMore)
        assertEquals(1, failed.nextPage)

        val retried = failed.beginNextPage()!!
        assertNull(retried.failure)
        assertEquals(90, retried.loaded(1, (51..90).toList(), 90).items.size)
    }

    @Test
    fun failedRefreshRetainsTheListAlreadyShown() {
        val loaded = started().loaded(0, listOf(1, 2, 3), 3)
        val refreshing = loaded.refresh()
        val failed = refreshing.fail(refreshing.generation, page = 0)

        assertEquals(BookOrbitPageFailure.REFRESH, failed.failure)
        assertEquals(listOf(1, 2, 3), failed.items)
        assertEquals(3, failed.total)
        assertFalse(failed.loading)
    }

    @Test
    fun failedFirstLoadIsAnExplicitErrorNotAnEmptyResult() {
        val first = started()
        val failed = first.fail(first.generation, page = 0)

        assertEquals(BookOrbitPageFailure.FIRST_PAGE, failed.failure)
        assertTrue(failed.items.isEmpty())
        assertNull(failed.total)
        assertFalse(failed.hasMore)
    }

    @Test
    fun selectionOrSearchChangeResetsItemsTotalsAndPaging() {
        val loaded = started().loaded(0, (1..50).toList(), 200).beginNextPage()!!.loaded(1, (51..100).toList(), 200)
        val restarted = loaded.restart()

        assertTrue(restarted.items.isEmpty())
        assertNull(restarted.total)
        assertEquals(0, restarted.nextPage)
        assertTrue(restarted.showsFirstLoad)
        assertTrue(restarted.generation > loaded.generation)
    }

    @Test
    fun responsesAndFailuresFromASupersededRequestAreIgnored() {
        val old = started()
        val current = old.restart()

        assertSame(current, current.receive(old.generation, 0, listOf(9, 9, 9), 3) { it })
        assertSame(current, current.fail(old.generation, 0))

        val loaded = current.loaded(0, listOf(1), 40)
        val loadingMore = loaded.beginNextPage()!!
        val refreshed = loadingMore.refresh()
        assertSame(refreshed, refreshed.receive(loadingMore.generation, 1, listOf(2), 40) { it })
        assertFalse(refreshed.loadingMore)
    }

    @Test
    fun repeatedRowsAcrossPagesAreNotDuplicated() {
        val list = started().loaded(0, listOf(1, 2, 3), 5).beginNextPage()!!.loaded(1, listOf(3, 4, 5), 5)

        assertEquals(listOf(1, 2, 3, 4, 5), list.items)
        assertFalse(list.hasMore)
    }

    @Test
    fun emptyNextPageEndsPagingEvenWhenTheTotalClaimsMore() {
        val list = started().loaded(0, listOf(1, 2), 10).beginNextPage()!!.loaded(1, emptyList(), 10)

        assertFalse(list.hasMore)
        assertEquals(10, list.total)
    }

    @Test
    fun emptyFirstPageIsAnEmptyResultWithZeroTotal() {
        val list = started().loaded(0, emptyList(), 0)

        assertTrue(list.items.isEmpty())
        assertEquals(0, list.total)
        assertNull(list.failure)
        assertFalse(list.hasMore)
    }

    @Test
    fun nextPageIsNotRequestedWhileAnotherLoadIsInFlight() {
        val loaded = started().loaded(0, listOf(1), 9)

        assertNull(loaded.beginNextPage()!!.beginNextPage())
        assertNull(loaded.refresh().beginNextPage())
        assertNull(started().beginNextPage())
    }

    @Test
    fun removingAndReplacingRowsKeepsTotalsTruthful() {
        val loaded = started().loaded(0, listOf(1, 2, 3), 12)

        val removed = loaded.removing { it == 2 }
        assertEquals(listOf(1, 3), removed.items)
        assertEquals(11, removed.total)
        assertSame(loaded, loaded.removing { it == 99 })
        assertEquals(listOf(1, 20, 3), loaded.replacing({ it == 2 }, 20).items)
    }
}
