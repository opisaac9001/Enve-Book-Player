package com.enve.hearth.library

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import org.junit.Assert.assertEquals
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
    fun restoringNeverRevivesDeletedDisabledOrExcludedScopes() {
        val saved = LibrarySelection(BookSource.KOMGA, "komga::comics", "komga")

        assertEquals(LibrarySelection(), restorableLibrarySelection(saved, emptySet(), emptyList(), emptyList(), emptySet()))
        assertEquals(LibrarySelection(), restorableLibrarySelection(saved, emptySet(), emptyList(), listOf(komga.copy(enabled = false)), emptySet()))
        assertEquals(LibrarySelection(), restorableLibrarySelection(saved, setOf(BookSource.AUDIOBOOKSHELF), libraries, listOf(komga, abs), emptySet()))
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
