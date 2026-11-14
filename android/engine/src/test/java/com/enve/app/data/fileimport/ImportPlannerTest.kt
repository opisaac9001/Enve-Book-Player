package com.enve.app.data.fileimport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream

class ImportPlannerTest {
    private fun file(name: String, identity: String? = "id:$name", size: Long = 1L, folder: ImportFolder? = null) =
        ImportFile(name, size, identity, folder) { ByteArrayInputStream(ByteArray(0)) }

    private val books = ImportFolder("tree:books", "The Long Way")
    private val otherBooks = ImportFolder("tree:other", "The Long Way")

    @Test
    fun skipsUnsupportedFilesAndDuplicateIdentities() {
        val items = ImportPlanner.plan(
            listOf(file("Notes.txt"), file("Dune.epub"), file("Dune copy.epub", identity = "id:Dune.epub"), file("Scan.cbz")),
            AudioGrouping.AUTOMATIC,
        )

        assertEquals(listOf("Dune", "Scan"), items.map { it.title })
        assertTrue(items.all { it is ImportItem.Document })
    }

    @Test
    fun keepsFilesWithoutIdentityEvenWhenNamesMatch() {
        val items = ImportPlanner.plan(listOf(file("Story.epub", null), file("Story.epub", null)), AudioGrouping.AUTOMATIC)

        assertEquals(2, items.size)
    }

    @Test
    fun separateGroupingMakesOneAudiobookPerFile() {
        val items = ImportPlanner.plan(
            listOf(file("Chapter 2.mp3", folder = books), file("Chapter 1.mp3", folder = books)),
            AudioGrouping.SEPARATE,
        )

        assertEquals(listOf("Chapter 2", "Chapter 1"), items.map { it.title })
        assertTrue(items.all { (it as ImportItem.Audiobook).tracks.size == 1 })
    }

    @Test
    fun singleBookOrdersTracksNumericallyAndUsesFolderName() {
        val items = ImportPlanner.plan(
            listOf(
                file("Chapter 10.mp3", folder = books),
                file("Chapter 2.mp3", folder = books),
                file("Chapter 1.mp3", folder = books),
                file("cover.jpg", folder = books),
            ),
            AudioGrouping.SINGLE_BOOK,
        )

        val book = items.single() as ImportItem.Audiobook
        assertEquals("The Long Way", book.title)
        assertEquals(listOf("Chapter 1.mp3", "Chapter 2.mp3", "Chapter 10.mp3"), book.tracks.map { it.name })
    }

    @Test
    fun singleBookWithoutFolderInfersTitleFromTrackNames() {
        val items = ImportPlanner.plan(
            listOf(file("Dune - Part 02.mp3"), file("Dune - Part 01.mp3")),
            AudioGrouping.SINGLE_BOOK,
        )

        assertEquals("Dune", items.single().title)
    }

    @Test
    fun neverGroupsTracksFromDifferentFoldersEvenWithTheSameName() {
        val items = ImportPlanner.plan(
            listOf(
                file("Chapter 1.mp3", identity = "a1", folder = books),
                file("Chapter 1.mp3", identity = "b1", folder = otherBooks),
                file("Chapter 2.mp3", identity = "a2", folder = books),
                file("Chapter 2.mp3", identity = "b2", folder = otherBooks),
            ),
            AudioGrouping.SINGLE_BOOK,
        )

        val audiobooks = items.map { it as ImportItem.Audiobook }
        assertEquals(2, audiobooks.size)
        assertEquals(listOf("a1", "a2"), audiobooks[0].tracks.map { it.identity })
        assertEquals(listOf("b1", "b2"), audiobooks[1].tracks.map { it.identity })
    }

    @Test
    fun automaticGroupingStaysInsideEachFolder() {
        val items = ImportPlanner.plan(
            listOf(
                file("01 Intro.mp3", identity = "a1", folder = books),
                file("02 Next.mp3", identity = "a2", folder = books),
                file("03 End.mp3", identity = "b3", folder = ImportFolder("tree:sequel", "Sequel")),
            ),
            AudioGrouping.AUTOMATIC,
        )

        assertEquals(listOf("The Long Way", "03 End"), items.map { it.title })
        assertEquals(listOf(2, 1), items.map { it.files.size })
    }

    @Test
    fun pickedFilesWithoutFolderIdentityGroupTogether() {
        val items = ImportPlanner.plan(
            listOf(file("Book Chapter 2.mp3"), file("Book Chapter 1.mp3")),
            AudioGrouping.AUTOMATIC,
        )

        assertEquals("Book", items.single().title)
    }

    @Test
    fun automaticGroupingSeparatesStandaloneBooksFromChapterSets() {
        val items = ImportPlanner.plan(
            listOf(
                file("Book Chapter 2.mp3", folder = books),
                file("Other.m4b", folder = books),
                file("Book Chapter 1.mp3", folder = books),
            ),
            AudioGrouping.AUTOMATIC,
        )

        val audiobooks = items.map { it as ImportItem.Audiobook }
        assertEquals(listOf("Book", "Other"), audiobooks.map { it.title })
        assertEquals(listOf("Book Chapter 1.mp3", "Book Chapter 2.mp3"), audiobooks.first().tracks.map { it.name })
    }

    @Test
    fun automaticGroupingUsesFolderNameForASingleChapterSet() {
        val items = ImportPlanner.plan(
            listOf(file("02 Next.mp3", folder = books), file("01 Intro.mp3", folder = books)),
            AudioGrouping.AUTOMATIC,
        )

        assertEquals("The Long Way", items.single().title)
    }

    @Test
    fun documentsComeBeforeAudiobooks() {
        val items = ImportPlanner.plan(listOf(file("Track.mp3"), file("Book.pdf")), AudioGrouping.AUTOMATIC)

        assertTrue(items[0] is ImportItem.Document)
        assertTrue(items[1] is ImportItem.Audiobook)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsOversizedSelections() {
        ImportPlanner.plan(List(ImportPlanner.MAX_FILES + 1) { file("$it.epub") }, AudioGrouping.AUTOMATIC)
    }

    @Test
    fun bookIdIsStableForTheSameSourcesAndSafeForStorage() {
        val first = ImportPlanner.bookId(ImportItem.Document(file("A.epub")))
        val second = ImportPlanner.bookId(ImportItem.Document(file("A.epub")))

        assertEquals(first, second)
        assertTrue(first.matches(Regex("local-file-[0-9a-f]{40}")))
    }

    @Test
    fun bookIdSeparatesFormatsAndTrackSets() {
        val document = ImportPlanner.bookId(ImportItem.Document(file("A.mp3")))
        val audiobook = ImportPlanner.bookId(ImportItem.Audiobook("A", listOf(file("A.mp3"))))
        val longer = ImportPlanner.bookId(ImportItem.Audiobook("A", listOf(file("A.mp3"), file("B.mp3"))))

        assertNotEquals(document, audiobook)
        assertNotEquals(audiobook, longer)
    }

    @Test
    fun bookIdIsUniqueWhenAnySourceHasNoIdentity() {
        val item = ImportItem.Audiobook("A", listOf(file("A.mp3"), file("B.mp3", identity = null)))

        assertNotEquals(ImportPlanner.bookId(item), ImportPlanner.bookId(item))
    }

    @Test
    fun formatsCoverLocalLibraryEbooksAndPlayableAudio() {
        listOf("Book.KEPUB", "Book.epub", "Book.pdf", "Book.azw3", "Comic.cbz", "Comic.cbr").forEach {
            assertEquals(it, ImportedFileKind.EBOOK, ImportableFormats.kind(it))
        }
        listOf("a.mp3", "a.M4B", "a.m4a", "a.mp4", "a.aac", "a.ogg", "a.oga", "a.opus", "a.flac", "a.wav").forEach {
            assertEquals(it, ImportedFileKind.AUDIO, ImportableFormats.kind(it))
        }
        listOf("Doc.docx", "Folder.zip", "epub", "cover.jpg").forEach { assertEquals(it, null, ImportableFormats.kind(it)) }
        assertTrue(ImportableFormats.zipContainerExtensions.all { ImportableFormats.kind("x.$it") == ImportedFileKind.EBOOK })
    }
}
