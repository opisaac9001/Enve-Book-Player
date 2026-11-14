package com.enve.hearth.library

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ComicMetadata
import com.enve.core.data.model.ComicSection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ComicLibraryBrowseTest {
    private fun issue(
        id: String,
        seriesId: String = "saga",
        section: ComicSection = ComicSection.ISSUES,
        volumeId: String? = null,
        volumeOrder: Double? = null,
        issueOrder: Double? = null,
        libraryId: String = "conn::comics",
        connectionId: String = "conn",
        progress: Float = 0f,
        finished: Boolean = false,
        seriesName: String? = "Saga",
    ) = Book(
        id = id,
        title = "Saga $id",
        source = BookSource.KAVITA,
        mediaType = AppMediaType.EBOOK,
        primaryFileType = "CBZ",
        connectionId = connectionId,
        libraryId = libraryId,
        seriesName = seriesName,
        readProgress = progress,
        isFinished = finished,
        comic = ComicMetadata(
            seriesId = seriesId,
            section = section,
            volumeId = volumeId,
            volumeTitle = volumeId?.let { "Volume $it" },
            volumeOrder = volumeOrder,
            issueLabel = issueOrder?.let { "#${formatComicNumber(it)}" },
            issueOrder = issueOrder,
        ),
    )

    private fun comicSeriesKey(book: Book) = comicSeriesSummaries(listOf(book)).single().key

    @Test
    fun groupingOrdersSectionsVolumesAndIssues() {
        val grouping = ComicSeriesGrouping.of(
            listOf(
                issue("special", section = ComicSection.SPECIALS),
                issue("v2-1", section = ComicSection.VOLUMES, volumeId = "2", volumeOrder = 2.0, issueOrder = 1.0),
                issue("v1-2", section = ComicSection.VOLUMES, volumeId = "1", volumeOrder = 1.0, issueOrder = 2.0),
                issue("v1-1", section = ComicSection.VOLUMES, volumeId = "1", volumeOrder = 1.0, issueOrder = 1.0),
                issue("loose-unnumbered"),
                issue("loose-3", issueOrder = 3.0),
                issue("v1-1", section = ComicSection.VOLUMES, volumeId = "1", volumeOrder = 1.0, issueOrder = 1.0),
            ),
        )

        assertEquals(listOf(ComicSection.ISSUES, ComicSection.VOLUMES, ComicSection.SPECIALS), grouping.sections.map { it.section })
        assertEquals(listOf("loose-3", "loose-unnumbered"), grouping.section(ComicSection.ISSUES)!!.looseBooks.map { it.id })
        val volumes = grouping.section(ComicSection.VOLUMES)!!.volumes
        assertEquals(listOf("VOLUMES/1", "VOLUMES/2"), volumes.map { it.id })
        assertEquals(listOf("v1-1", "v1-2"), volumes.first().books.map { it.id })
        assertEquals("Volume 1", volumes.first().displayTitle)
        assertEquals(6, grouping.bookCount)
    }

    @Test
    fun aSingleVolumeWithoutLooseIssuesOpensDirectly() {
        val grouping = ComicSeriesGrouping.of(
            listOf(issue("a", section = ComicSection.VOLUMES, volumeId = "9", volumeOrder = 9.0, issueOrder = 1.0)),
        )

        assertEquals("VOLUMES/9", grouping.section(ComicSection.VOLUMES)!!.directVolume?.id)
        assertNull(ComicSeriesGrouping.of(listOf(issue("a", section = ComicSection.VOLUMES, volumeId = "9"), issue("b", section = ComicSection.VOLUMES)))
            .section(ComicSection.VOLUMES)!!.directVolume)
    }

    @Test
    fun seriesIdentityIsScopedToConnectionLibraryAndServerSeries() {
        val books = listOf(
            issue("1", seriesId = "100"),
            issue("2", seriesId = "200"),
            issue("3", seriesId = "100", libraryId = "conn::manga"),
            issue("4", seriesId = "100", connectionId = "other", libraryId = "other::comics"),
            issue("5", seriesId = "100"),
        )

        val series = comicSeriesSummaries(books)

        assertEquals(4, series.size)
        assertEquals(setOf(2, 1), series.map { it.total }.toSet())
        assertEquals(comicSeriesKey(books[0]), comicSeriesKey(books[4]))
    }

    @Test
    fun serverRowsMissingMetadataStayIndividualUntilRefreshRestoresIt() {
        val stale = listOf(
            issue("1").copy(comic = null),
            issue("2").copy(comic = null),
            issue("3").copy(source = BookSource.KOMGA, comic = null),
            issue("4").copy(source = BookSource.KOMGA, comic = null),
        )

        val series = comicSeriesSummaries(stale)

        assertEquals(4, series.size)
        assertTrue(series.all { comicSeriesView(it.key, stale, stale, ComicBrowseState())!!.isStandalone })
        assertEquals(1, comicSeriesSummaries(stale.map { it.copy(comic = ComicMetadata("saga")) }.take(2)).size)
    }

    @Test
    fun importedComicsWithoutProviderIdsGroupByNameWithinTheirLibraryOnly() {
        fun local(id: String, libraryId: String = "local::comics", seriesName: String? = "Saga") =
            issue(id, libraryId = libraryId, connectionId = "local", seriesName = seriesName)
                .copy(source = BookSource.LOCAL, comic = null)
        val books = listOf(local("1"), local("2"), local("3", libraryId = "local::other"), local("4", seriesName = " "))

        val series = comicSeriesSummaries(books)

        assertEquals(listOf(2, 1, 1), series.map { it.total }.sortedDescending())
        val named = series.first { it.total == 2 }
        assertFalse(comicSeriesView(named.key, books, books, ComicBrowseState())!!.isStandalone)
        assertTrue(comicSeriesView(comicSeriesKey(books[3]), books, books, ComicBrowseState())!!.isStandalone)
    }

    @Test
    fun seriesKeysKeepConnectionAndLibraryApartWhateverTheirCharacters() {
        val first = issue("1", seriesId = "x", connectionId = "a|b", libraryId = "c")
        val second = issue("2", seriesId = "x", connectionId = "a", libraryId = "b|c")
        val quoted = issue("3", seriesId = "id:\"x\"|y", connectionId = "a::b;=,", libraryId = "a::b;=,::lib")
        val books = listOf(first, second, quoted)

        assertEquals(3, comicSeriesSummaries(books).size)
        assertEquals(listOf("3"), comicSeriesView(comicSeriesKey(quoted), books, books, ComicBrowseState())!!.grouping.orderedBooks.map { it.id })
        assertNull(comicSeriesView("conn|conn::comics|id:saga", books, books, ComicBrowseState()))
    }

    @Test
    fun seriesRunSpansTheirPublishedYears() {
        val books = listOf(
            issue("1").copy(publishedDate = "1986-04-01"),
            issue("2").copy(publishedDate = "c. 1990"),
            issue("3").copy(publishedDate = null),
        )

        assertEquals("1986–1990", comicSeriesSummaries(books).single().run)
        assertEquals(1986, publishedYear(books[0]))
        assertNull(publishedYear(books[2]))
    }

    @Test
    fun continuingPrefersTheIssueInProgressThenTheNextUnread() {
        val read = issue("1", issueOrder = 1.0, finished = true)
        val next = issue("2", issueOrder = 2.0)
        val started = issue("3", issueOrder = 3.0, progress = 0.4f)

        assertEquals("3", nextComicIssue(listOf(read, next, started))?.id)
        assertEquals("2", nextComicIssue(listOf(read, next))?.id)
        assertEquals("1", nextComicIssue(listOf(read))?.id)
        assertEquals("Read again", comicContinueTitle(read))
        assertEquals("Continue reading", comicContinueTitle(started))
        assertEquals("Read next", comicContinueTitle(next))
    }

    @Test
    fun openingASeriesSelectsAndExpandsTheResumeVolume() {
        val books = listOf(
            issue("v1", section = ComicSection.VOLUMES, volumeId = "1", volumeOrder = 1.0, finished = true),
            issue("v2", section = ComicSection.VOLUMES, volumeId = "2", volumeOrder = 2.0),
            issue("loose", finished = true),
        )
        val series = comicSeriesSummaries(books).single()

        val state = openedComicSeriesState(ComicBrowseState(columns = 2), series)

        assertEquals(comicSeriesKey(books.first()), state.seriesKey)
        assertEquals(ComicSection.VOLUMES, state.section)
        assertEquals(setOf("VOLUMES/2"), state.expandedVolumeIds)
        assertEquals(2, state.columns)
    }

    @Test
    fun seriesViewKeepsNavigationWhenFiltersHideEveryIssue() {
        val books = listOf(issue("1"), issue("2", section = ComicSection.SPECIALS))
        val key = comicSeriesKey(books.first())
        val state = ComicBrowseState(seriesKey = key, section = ComicSection.SPECIALS, expandedVolumeIds = setOf("VOLUMES/1"))

        val view = comicSeriesView(key, catalog = books, visible = emptyList(), state = state)!!

        assertEquals("Saga", view.name)
        assertTrue(view.hasNoVisibleIssues)
        assertEquals(setOf("VOLUMES/1"), view.expandedVolumeIds)
        assertEquals(ComicSection.SPECIALS, comicSeriesView(key, books, books, state)!!.selectedSection)
        assertEquals(ComicSection.ISSUES, comicSeriesView(key, books, books.take(1), state)!!.selectedSection)
        assertNull(comicSeriesView("missing", books, books, state))
    }

    @Test
    fun browseStateSurvivesPersistence() {
        val state = ComicBrowseState(
            facet = LibraryFacet.BOOKS,
            columns = 1,
            seriesKey = comicSeriesKey(issue("1", connectionId = "a|b;=,", libraryId = "a|b;=,::\"lib\"")),
            section = ComicSection.VOLUMES,
            expandedVolumeIds = setOf("VOLUMES/2", "VOLUMES/1,3"),
        )

        assertEquals(state, decodeComicBrowseState(encodeComicBrowseState(state)))
        assertEquals(ComicBrowseState(), decodeComicBrowseState(""))
        assertEquals(ComicBrowseState(), decodeComicBrowseState("f=BOOKS;c=1"))
        assertEquals(ComicBrowseState(), decodeComicBrowseState("""{"section":"UNKNOWN"}"""))
        val sanitized = decodeComicBrowseState("""{"facet":"AUTHORS","columns":9,"future":true}""")
        assertEquals(LibraryFacet.SERIES, sanitized.facet)
        assertEquals(4, sanitized.columns)
    }

    @Test
    fun scopesSeparateLibrariesFromWholeSources() {
        assertEquals("all", libraryScopeKey(null, null))
        assertEquals("source:KAVITA", libraryScopeKey(BookSource.KAVITA, null))
        assertEquals("library:conn::comics", libraryScopeKey(BookSource.KAVITA, "conn::comics"))
        assertFalse(libraryScopeKey(null, "a::b") == libraryScopeKey(null, "c::b"))
    }
}
