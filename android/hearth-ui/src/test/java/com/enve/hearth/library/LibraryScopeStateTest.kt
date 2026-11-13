package com.enve.hearth.library

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryScopeStateTest {
    private val comic = Book(
        id = "issue", title = "Issue", source = BookSource.KOMGA, mediaType = AppMediaType.EBOOK,
        primaryFileType = "CBZ", connectionId = "komga", libraryId = "komga::comics",
    )
    private val novel = comic.copy(id = "novel", primaryFileType = "EPUB", libraryId = "komga::books")
    private val audiobook = Book(
        id = "audio", title = "Audio", source = BookSource.AUDIOBOOKSHELF,
        connectionId = "abs", libraryId = "abs::audio",
    )
    private val catalog = listOf(comic, novel, audiobook)

    private val komga = ProviderConnection("komga", BookSource.KOMGA, "Komga", "https://komga.test", "reader")
    private val abs = ProviderConnection("abs", BookSource.AUDIOBOOKSHELF, "ABS", "https://abs.test", "listener")
    private val libraries = listOf(
        Library("komga::comics", "Comics", source = BookSource.KOMGA, connectionId = "komga"),
        Library("abs::audio", "Audio", source = BookSource.AUDIOBOOKSHELF, connectionId = "abs"),
    )

    @Test
    fun aComicsOnlyScopeOpensOnComicsUnlessTheReaderChoseOtherwise() {
        assertEquals(MediaFilter.COMICS, resolveLibraryMedia(null, catalog, BookSource.KOMGA, "komga::comics"))
        assertEquals(MediaFilter.ALL, resolveLibraryMedia(MediaFilter.ALL, catalog, BookSource.KOMGA, "komga::comics"))
        assertEquals(MediaFilter.ALL, resolveLibraryMedia(null, catalog, BookSource.KOMGA, null))
        assertEquals(MediaFilter.COMICS, resolveLibraryMedia(null, listOf(comic, audiobook), BookSource.KOMGA, null))
        assertEquals(MediaFilter.ALL, resolveLibraryMedia(null, listOf(comic), null, null))
        assertEquals(MediaFilter.ALL, resolveLibraryMedia(null, emptyList(), BookSource.KOMGA, "komga::comics"))
        assertEquals(MediaFilter.AUDIOBOOKS, resolveLibraryMedia(MediaFilter.AUDIOBOOKS, emptyList(), null, null))
    }

    @Test
    fun librarySelectionRoundTripsWhateverItsIdentifiersContain() {
        val selection = LibrarySelection(BookSource.KOMGA, "komga::\"comics\";=,|x", "komga")

        assertEquals(selection, decodeLibrarySelection(encodeLibrarySelection(selection)))
        assertEquals(LibrarySelection(), decodeLibrarySelection(""))
        assertEquals(LibrarySelection(), decodeLibrarySelection("""{"source":"RETIRED"}"""))
    }

    @Test
    fun restoringKeepsLiveScopesWhileCatalogDataIsStillEmpty() {
        val saved = LibrarySelection(BookSource.KOMGA, "komga::comics", "komga")

        assertEquals(saved, restorableLibrarySelection(saved, setOf(BookSource.KOMGA), libraries, listOf(komga), emptySet()))
        assertEquals(saved, restorableLibrarySelection(saved, emptySet(), emptyList(), listOf(komga), emptySet()))
        val local = LibrarySelection(BookSource.LOCAL)
        assertEquals(local, restorableLibrarySelection(local, setOf(BookSource.LOCAL), emptyList(), emptyList(), emptySet()))
    }

    @Test
    fun anUnrelatedCatalogDoesNotDisplaceSavedScopes() {
        val saved = LibrarySelection(BookSource.KOMGA, "komga::comics", "komga")
        val otherLibraries = libraries.filter { it.connectionId == abs.id }

        assertEquals(saved, restorableLibrarySelection(saved, setOf(BookSource.AUDIOBOOKSHELF), otherLibraries, listOf(komga, abs), emptySet()))
        assertEquals(saved, restorableLibrarySelection(saved, setOf(BookSource.AUDIOBOOKSHELF), libraries, listOf(komga, abs), emptySet()))
        assertEquals(
            LibrarySelection(BookSource.LOCAL),
            restorableLibrarySelection(LibrarySelection(BookSource.LOCAL), setOf(BookSource.AUDIOBOOKSHELF), otherLibraries, listOf(abs), emptySet()),
        )
    }

    @Test
    fun audiobookPreferenceSurvivesStaggeredCatalogRestoration() {
        val saved = LibrarySelection(BookSource.AUDIOBOOKSHELF, "abs::audio", "abs")
        val snapshots = listOf(
            emptyList<Book>() to emptyList<Library>(),
            listOf(comic) to libraries.filter { it.connectionId == komga.id },
            catalog to libraries,
            emptyList<Book>() to emptyList<Library>(),
        )

        repeat(2) {
            for ((books, availableLibraries) in snapshots) {
                val restored = restorableLibrarySelection(
                    saved, books.map(Book::source), availableLibraries, listOf(komga, abs), emptySet(),
                )
                assertEquals(saved, restored)
                assertEquals("library:abs::audio", libraryScopeKey(restored.source, restored.libraryId))
                assertEquals(MediaFilter.AUDIOBOOKS, resolveLibraryMedia(MediaFilter.AUDIOBOOKS, books, restored.source, restored.libraryId))
            }
        }
    }

    @Test
    fun staggeredServersAndOfflineStartupNeverDropTheSavedScope() = runBlocking {
        val saved = LibrarySelection(BookSource.AUDIOBOOKSHELF, "abs::audio", "abs")
        val books = MutableStateFlow<List<Book>>(emptyList())
        val available = MutableStateFlow<List<Library>>(emptyList())
        val emissions = mutableListOf<LibrarySelection>()
        val collector = launch {
            librarySelectionFlow(
                MutableStateFlow(encodeLibrarySelection(saved)),
                MutableStateFlow(null),
                books.map { list -> list.map(Book::source) },
                available,
                MutableStateFlow(listOf(komga, abs)),
                MutableStateFlow(emptySet()),
            ).collect { emissions += it }
        }

        settle()
        books.value = listOf(comic)
        available.value = libraries.filter { it.connectionId == komga.id }
        settle()
        books.value = catalog
        available.value = libraries
        settle()
        books.value = emptyList()
        available.value = emptyList()
        settle()
        collector.cancel()

        assertTrue(emissions.isNotEmpty())
        assertEquals(listOf(saved), emissions.distinct())
    }

    @Test
    fun hiddenScopesComeBackWhenTheirConnectionIsReenabled() = runBlocking {
        val saved = LibrarySelection(BookSource.KOMGA, "komga::comics", "komga")
        val connections = MutableStateFlow(listOf(komga, abs))
        val excluded = MutableStateFlow(emptySet<String>())
        val selection = librarySelectionFlow(
            MutableStateFlow(encodeLibrarySelection(saved)),
            MutableStateFlow(null),
            MutableStateFlow(setOf(BookSource.AUDIOBOOKSHELF)),
            MutableStateFlow(libraries),
            connections,
            excluded,
        )

        connections.value = listOf(komga.copy(enabled = false), abs)
        assertEquals(LibrarySelection(), selection.first())
        connections.value = listOf(abs)
        assertEquals(LibrarySelection(), selection.first())
        connections.value = listOf(komga, abs)
        assertEquals(saved, selection.first())
        excluded.value = setOf("komga::comics")
        assertEquals(LibrarySelection(BookSource.KOMGA), selection.first())
        excluded.value = emptySet()
        assertEquals(saved, selection.first())
    }

    @Test
    fun theLatestUserChoiceOutranksStaleSavedEchoes() = runBlocking {
        val stored = MutableStateFlow(encodeLibrarySelection(LibrarySelection(BookSource.AUDIOBOOKSHELF)))
        val requested = MutableStateFlow<LibrarySelection?>(null)
        val selection = librarySelectionFlow(
            stored,
            requested,
            MutableStateFlow(setOf(BookSource.KOMGA, BookSource.AUDIOBOOKSHELF)),
            MutableStateFlow(libraries),
            MutableStateFlow(listOf(komga, abs)),
            MutableStateFlow(emptySet()),
        )
        val chosen = LibrarySelection(BookSource.KOMGA, "komga::comics", "komga")

        assertEquals(LibrarySelection(BookSource.AUDIOBOOKSHELF), selection.first())
        requested.value = LibrarySelection(BookSource.KOMGA)
        requested.value = chosen
        assertEquals(chosen, selection.first())
        stored.value = encodeLibrarySelection(LibrarySelection(BookSource.KOMGA))
        assertEquals(chosen, selection.first())
        stored.value = encodeLibrarySelection(chosen)
        assertEquals(chosen, selection.first())
    }

    private suspend fun settle() = repeat(50) { yield() }

    @Test
    fun restoringNeverRevivesDeletedDisabledOrExcludedScopes() {
        val saved = LibrarySelection(BookSource.KOMGA, "komga::comics", "komga")

        assertEquals(LibrarySelection(), restorableLibrarySelection(saved, emptySet(), emptyList(), emptyList(), emptySet()))
        assertEquals(LibrarySelection(), restorableLibrarySelection(saved, emptySet(), emptyList(), listOf(komga.copy(enabled = false)), emptySet()))
        assertEquals(
            LibrarySelection(BookSource.KOMGA),
            restorableLibrarySelection(saved, setOf(BookSource.KOMGA), libraries, listOf(komga), setOf("komga::comics")),
        )
        assertEquals(
            LibrarySelection(BookSource.KOMGA),
            restorableLibrarySelection(saved.copy(libraryId = "komga::gone"), setOf(BookSource.KOMGA), libraries, listOf(komga), emptySet()),
        )
        assertEquals(
            LibrarySelection(libraryId = "abs::audio", connectionId = "abs"),
            restorableLibrarySelection(LibrarySelection(libraryId = "abs::audio", connectionId = "abs"), emptySet(), libraries, listOf(abs), emptySet()),
        )
    }
}
