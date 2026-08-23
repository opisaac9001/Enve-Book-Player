package com.enve.hearth.home

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.engine.library.LibraryEditionLink
import org.junit.Assert.assertEquals
import org.junit.Test

class SplitContinueShelvesTest {

    private fun book(
        id: String,
        media: AppMediaType,
        readAlong: Boolean = false,
    ) = Book(id = id, title = "Book $id", mediaType = media, readAlongAvailable = readAlong)

    private fun keys(books: List<Book>) = books.map { it.uniqueKey }

    @Test
    fun pureAudiobookGoesToListening_pureEbookToReading() {
        val audio = book("1", AppMediaType.AUDIOBOOK)
        val ebook = book("2", AppMediaType.EBOOK)
        val (listening, reading) = splitContinueShelves(listOf(audio, ebook), emptyList())
        assertEquals(listOf(audio.uniqueKey), keys(listening))
        assertEquals(listOf(ebook.uniqueKey), keys(reading))
    }

    @Test
    fun readAloudAudiobookIsForcedToReading() {
        val readAloud = book("1", AppMediaType.AUDIOBOOK, readAlong = true)
        val (listening, reading) = splitContinueShelves(listOf(readAloud), emptyList())
        assertEquals(emptyList<String>(), keys(listening))
        assertEquals(listOf(readAloud.uniqueKey), keys(reading))
    }

    @Test
    fun linkedPairBothInProgress_showsOnceUnderReading() {
        val ebook = book("e", AppMediaType.EBOOK)
        val audio = book("a", AppMediaType.AUDIOBOOK)
        val links = listOf(LibraryEditionLink(ebookKey = ebook.uniqueKey, audiobookKey = audio.uniqueKey))
        val (listening, reading) = splitContinueShelves(listOf(ebook, audio), links)
        assertEquals(emptyList<String>(), keys(listening))
        assertEquals(listOf(ebook.uniqueKey), keys(reading))
    }

    @Test
    fun linkedAudiobookAloneStillGoesToReading() {
        val audio = book("a", AppMediaType.AUDIOBOOK)

        val links = listOf(LibraryEditionLink(ebookKey = "GRIMMORY:e", audiobookKey = audio.uniqueKey))
        val (listening, reading) = splitContinueShelves(listOf(audio), links)
        assertEquals(emptyList<String>(), keys(listening))
        assertEquals(listOf(audio.uniqueKey), keys(reading))
    }
}
