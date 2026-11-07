package com.enve.hearth.home

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.engine.library.LibraryEditionLink
import com.enve.hearth.includesLibraryBook
import org.junit.Assert.assertEquals
import org.junit.Test

class SplitContinueShelvesTest {

    private fun book(
        id: String,
        media: AppMediaType,
        readAlong: Boolean = false,
        hasAudio: Boolean = false,
    ) = Book(id = id, title = "Book $id", mediaType = media, readAlongAvailable = readAlong, hasAudio = hasAudio)

    private fun keys(books: List<Book>) = books.map { it.uniqueKey }

    @Test
    fun pureAudiobookGoesToListening_pureEbookToReading() {
        val audio = book("1", AppMediaType.AUDIOBOOK)
        val ebook = book("2", AppMediaType.EBOOK)
        val (listening, reading) = splitContinueShelves(listOf(audio, ebook), emptyList(), readingEnabled = true)
        assertEquals(listOf(audio.uniqueKey), keys(listening))
        assertEquals(listOf(ebook.uniqueKey), keys(reading))
    }

    @Test
    fun readAloudAudiobookIsForcedToReading() {
        val readAloud = book("1", AppMediaType.AUDIOBOOK, readAlong = true)
        val (listening, reading) = splitContinueShelves(listOf(readAloud), emptyList(), readingEnabled = true)
        assertEquals(emptyList<String>(), keys(listening))
        assertEquals(listOf(readAloud.uniqueKey), keys(reading))
    }

    @Test
    fun linkedPairBothInProgress_showsOnceUnderReading() {
        val ebook = book("e", AppMediaType.EBOOK)
        val audio = book("a", AppMediaType.AUDIOBOOK)
        val links = listOf(LibraryEditionLink(ebookKey = ebook.uniqueKey, audiobookKey = audio.uniqueKey))
        val (listening, reading) = splitContinueShelves(listOf(ebook, audio), links, readingEnabled = true)
        assertEquals(emptyList<String>(), keys(listening))
        assertEquals(listOf(ebook.uniqueKey), keys(reading))
    }

    @Test
    fun linkedAudiobookAloneStillGoesToReading() {
        val audio = book("a", AppMediaType.AUDIOBOOK)

        val links = listOf(LibraryEditionLink(ebookKey = "GRIMMORY:e", audiobookKey = audio.uniqueKey))
        val (listening, reading) = splitContinueShelves(listOf(audio), links, readingEnabled = true)
        assertEquals(emptyList<String>(), keys(listening))
        assertEquals(listOf(audio.uniqueKey), keys(reading))
    }

    @Test
    fun audiobooksOnlyListsEveryPlayableContinuationOnceUnderListening() {
        val plain = book("plain", AppMediaType.AUDIOBOOK)
        val readAloud = book("readaloud", AppMediaType.AUDIOBOOK, readAlong = true)
        val narrated = book("narrated", AppMediaType.EBOOK, readAlong = true, hasAudio = true)
        val linkedEbook = book("linked-e", AppMediaType.EBOOK, hasAudio = true)
        val linkedAudio = book("linked-a", AppMediaType.AUDIOBOOK)
        val orphanAudio = book("orphan-a", AppMediaType.AUDIOBOOK)
        val textOnly = book("text", AppMediaType.EBOOK)
        val links = listOf(
            LibraryEditionLink(ebookKey = linkedEbook.uniqueKey, audiobookKey = linkedAudio.uniqueKey),
            LibraryEditionLink(ebookKey = textOnly.uniqueKey, audiobookKey = orphanAudio.uniqueKey),
        )
        val continuing = listOf(plain, readAloud, narrated, linkedEbook, linkedAudio, orphanAudio, textOnly)
            .filter { includesLibraryBook(it, readingEnabled = false) }

        val (listening, reading) = splitContinueShelves(continuing, links, readingEnabled = false)

        assertEquals(keys(listOf(plain, readAloud, narrated, linkedAudio, orphanAudio)), keys(listening))
        assertEquals(emptyList<String>(), keys(reading))
    }
}
