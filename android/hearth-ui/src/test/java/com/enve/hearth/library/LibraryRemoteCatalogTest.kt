package com.enve.hearth.library

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.RemoteCatalogRequest
import com.enve.core.data.provider.RemoteCatalogSort
import com.enve.engine.library.RemoteLibraryPage
import com.enve.engine.library.RemoteLibraryRequest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryRemoteCatalogTest {
    private val selection = LibrarySelection(BookSource.SILO, "silo::fiction", "silo")

    private fun plan(
        facet: LibraryFacet = LibraryFacet.BOOKS,
        status: StatusFilter = StatusFilter.ALL,
        media: MediaFilter = MediaFilter.ALL,
        selection: LibrarySelection = this.selection,
        scopeSource: BookSource? = BookSource.SILO,
        advanced: LibraryAdvancedFilters = LibraryAdvancedFilters(),
        sort: List<SortDescriptor> = DEFAULT_SORT,
        query: String = "",
        siloEnabled: Boolean = true,
        readingEnabled: Boolean = true,
    ) = libraryCatalogPlan(facet, status, media, selection, scopeSource, advanced, sort, query, siloEnabled, setOf("silo::hidden"), readingEnabled)

    @Test
    fun browsingSiloBooksSendsSearchFiltersAndScopeToTheServer() {
        val result = plan(
            media = MediaFilter.AUDIOBOOKS,
            advanced = LibraryAdvancedFilters(genres = setOf("Fantasy"), languages = setOf("English")),
            query = "  dune ",
        )

        assertEquals(
            RemoteLibraryRequest(
                catalog = RemoteCatalogRequest(
                    search = "dune",
                    mediaType = AppMediaType.AUDIOBOOK,
                    sort = RemoteCatalogSort.RECENTLY_ADDED,
                    genres = setOf("Fantasy"),
                    languages = setOf("English"),
                ),
                source = BookSource.SILO,
                libraryId = "silo::fiction",
                connectionId = "silo",
                excludedLibraryIds = setOf("silo::hidden"),
            ),
            result.request,
        )
        assertNull(result.cachedNotice)
        assertNull(result.sortNotice)
    }

    @Test
    fun allSourcesBrowsingStaysLiveWhileOtherProvidersOrDisabledSiloStayLocal() {
        assertTrue(plan(selection = LibrarySelection(), scopeSource = null).live)
        assertEquals(LibraryCatalogPlan(), plan(scopeSource = BookSource.KOMGA))
        assertEquals(LibraryCatalogPlan(), plan(siloEnabled = false))
        assertEquals(LibraryCatalogPlan(), plan(facet = LibraryFacet.SHELVES))
    }

    @Test
    fun unsupportedSiloFiltersFallBackToCachedBooksWithAVisibleReason() {
        listOf(
            plan(advanced = LibraryAdvancedFilters(minimumRating = 4f)),
            plan(advanced = LibraryAdvancedFilters(series = SeriesFilter.STANDALONE)),
            plan(status = StatusFilter.UNREAD),
            plan(facet = LibraryFacet.AUTHORS),
            plan(media = MediaFilter.COMICS),
        ).forEach { result ->
            assertFalse(result.live)
            assertTrue(result.siloInScope)
            assertTrue(result.cachedNotice.orEmpty().contains("cached books only"))
        }
    }

    @Test
    fun onlyTitleAscendingAndRecentDescendingSortOnTheServer() {
        assertEquals(RemoteCatalogSort.TITLE, remoteCatalogSort(listOf(SortDescriptor(LibrarySort.TITLE, SortDirection.ASCENDING))))
        assertEquals(RemoteCatalogSort.RECENTLY_ADDED, remoteCatalogSort(emptyList()))
        assertNull(remoteCatalogSort(listOf(SortDescriptor(LibrarySort.TITLE, SortDirection.DESCENDING))))
        assertNull(remoteCatalogSort(DEFAULT_SORT + SortDescriptor(LibrarySort.AUTHOR, SortDirection.ASCENDING)))

        val fallback = plan(sort = listOf(SortDescriptor(LibrarySort.AUTHOR, SortDirection.ASCENDING)))
        assertEquals(RemoteCatalogSort.TITLE, fallback.request?.catalog?.sort)
        assertTrue(fallback.sortNotice.orEmpty().contains("by title"))
    }

    @Test
    fun listeningOnlyModeAsksTheServerForAudiobooks() {
        assertEquals(AppMediaType.AUDIOBOOK, plan(readingEnabled = false).request?.catalog?.mediaType)
        assertNull(plan().request?.catalog?.mediaType)
    }

    @Test
    fun mergedPagesHoldBackLocalBooksPastTheLastLoadedServerBook() {
        val comparator = remoteCatalogComparator(RemoteCatalogSort.TITLE)
        val local = listOf(book("zeta", BookSource.KOMGA), book("alpha", BookSource.KOMGA), book("kappa", BookSource.KOMGA))
        val remote = listOf(book("beta"), book("lambda"))

        assertEquals(listOf("alpha", "beta", "kappa", "lambda"), mergeCatalogPages(local, remote, comparator, remoteHasMore = true).map(Book::title))
        assertEquals(
            listOf("alpha", "beta", "kappa", "lambda", "zeta"),
            mergeCatalogPages(local, remote, comparator, remoteHasMore = false).map(Book::title),
        )
    }

    @Test
    fun filterOptionsAreCappedWhileSelectionsStayVisible() {
        val available = (1..30).map { "Genre %02d".format(it) }
        val (shown, hasMore) = visibleFilterOptions(available, selected = setOf("Picked"), typeahead = "")

        assertEquals(REMOTE_FILTER_OPTION_CAP + 1, shown.size)
        assertTrue("Picked" in shown)
        assertTrue(hasMore)

        val (matching, more) = visibleFilterOptions(available, selected = setOf("Picked"), typeahead = "genre 0")
        assertEquals(listOf("Genre 01", "Genre 02", "Genre 03", "Genre 04", "Genre 05", "Genre 06", "Genre 07", "Genre 08", "Genre 09", "Picked"), matching)
        assertFalse(more)
    }

    @Test
    fun aNewQueryDiscardsTheOldResultsAndOnlyTheLatestResponseLands() = runBlocking {
        val calls = mutableListOf<Call>()
        val pager = RemoteCatalogPager(this) { request, cursors -> Call(request, cursors).also(calls::add).page.await() }
        val first = RemoteLibraryRequest(source = BookSource.SILO)
        val second = first.copy(libraryId = "silo::fiction")

        pager.submit(first)
        yield()
        calls[0].page.complete(RemoteLibraryPage(listOf(book("old")), mapOf("lib" to "c1")))
        yield()
        assertEquals(listOf("old"), pager.state.value.books.map(Book::title))

        pager.submit(second)
        assertTrue(pager.state.value.books.isEmpty())
        assertTrue(pager.state.value.loading)
        yield()
        pager.submit(first)
        yield()
        calls[1].page.complete(RemoteLibraryPage(listOf(book("stale"))))
        calls[2].page.complete(RemoteLibraryPage(listOf(book("fresh"))))
        yield()

        assertEquals(first, pager.state.value.request)
        assertEquals(listOf("fresh"), pager.state.value.books.map(Book::title))
        assertFalse(pager.state.value.hasMore)
    }

    @Test
    fun loadMoreAppendsAndAFailedPageCanBeRetriedWithTheSameCursors() = runBlocking {
        val calls = mutableListOf<Call>()
        val pager = RemoteCatalogPager(this) { request, cursors -> Call(request, cursors).also(calls::add).page.await() }
        pager.submit(RemoteLibraryRequest(source = BookSource.SILO))
        yield()
        calls[0].page.complete(RemoteLibraryPage(listOf(book("a")), mapOf("lib" to "c1")))
        yield()

        pager.loadMore()
        yield()
        assertEquals(mapOf("lib" to "c1"), calls[1].cursors)
        calls[1].page.complete(RemoteLibraryPage(error = "Couldn't reach Silo."))
        yield()
        assertEquals("Couldn't reach Silo.", pager.state.value.error)
        assertEquals(listOf("a"), pager.state.value.books.map(Book::title))

        pager.retry()
        yield()
        assertEquals(mapOf("lib" to "c1"), calls[2].cursors)
        calls[2].page.complete(RemoteLibraryPage(listOf(book("b"))))
        yield()
        assertEquals(listOf("a", "b"), pager.state.value.books.map(Book::title))
        assertNull(pager.state.value.error)
        assertFalse(pager.state.value.hasMore)
    }

    @Test
    fun typingDebouncesWhileOtherChangesFetchImmediately() = runBlocking {
        val calls = mutableListOf<Call>()
        val pager = RemoteCatalogPager(this) { request, cursors -> Call(request, cursors).also(calls::add).page.await() }
        val base = RemoteLibraryRequest(catalog = RemoteCatalogRequest(search = "d"), source = BookSource.SILO)

        pager.submit(base)
        yield()
        assertEquals(1, calls.size)

        pager.submit(base.copy(catalog = base.catalog.copy(search = "du")))
        yield()
        assertEquals(1, calls.size)
        pager.submit(base.copy(catalog = base.catalog.copy(search = "dun")))
        delay(REMOTE_SEARCH_DEBOUNCE_MS + 100)
        assertEquals(2, calls.size)
        assertEquals("dun", calls[1].request.catalog.search)

        pager.submit(calls[1].request.copy(libraryId = "silo::fiction"))
        yield()
        assertEquals(3, calls.size)
        calls.forEach { it.page.cancel() }
    }

    @Test
    fun aConnectionChangeRestartsTheSameQuery() = runBlocking {
        val calls = mutableListOf<Call>()
        val pager = RemoteCatalogPager(this) { request, cursors -> Call(request, cursors).also(calls::add).page.await() }
        val request = RemoteLibraryRequest(source = BookSource.SILO)

        pager.submit(request, listOf("silo" to "https://a"))
        yield()
        pager.submit(request, listOf("silo" to "https://a"))
        yield()
        assertEquals(1, calls.size)
        pager.submit(request, listOf("silo" to "https://b"))
        yield()
        assertEquals(2, calls.size)
        calls.forEach { it.page.cancel() }
    }

    private class Call(val request: RemoteLibraryRequest, val cursors: Map<String, String>?) {
        val page = CompletableDeferred<RemoteLibraryPage>()
    }

    private fun book(title: String, source: BookSource = BookSource.SILO) =
        Book(id = title, title = title, source = source, connectionId = source.name.lowercase())
}
