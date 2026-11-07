package com.enve.hearth.library

import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import com.enve.hearth.hasPlayableAudio
import com.enve.hearth.includesLibraryBook
import com.enve.hearth.opensInPlayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadingModeFilterTest {
    private val audiobook = Book(id = "audio", title = "Audio")
    private val podcast = Book(id = "podcast", title = "Podcast", mediaType = AppMediaType.PODCAST)
    private val ebook = Book(id = "ebook", title = "Ebook", mediaType = AppMediaType.EBOOK)
    private val narrated = ebook.copy(id = "narrated", readAlongAvailable = true, hasAudio = true)

    @Test
    fun audiobooksOnlyKeepsListenableItems() {
        assertEquals(listOf("audio", "podcast", "narrated"), listOf(audiobook, podcast, ebook, narrated).filter { includesLibraryBook(it, false) }.map { it.id })
        assertTrue(listOf(audiobook, podcast, ebook, narrated).all { includesLibraryBook(it, true) })
    }

    @Test
    fun readAlongEditionsAndAudioMarksStayListenable() {
        val readAlongOnly = ebook.copy(id = "readalong", readAlongAvailable = true)

        assertTrue(readAlongOnly.hasPlayableAudio)
        assertTrue(includesLibraryBook(readAlongOnly, false))
        assertFalse(ebook.hasPlayableAudio)
        assertTrue(ReaderAnnotation(id = "a", bookId = "b", media = AnnotationMedia.AUDIOBOOK.name).opensInPlayer)
        assertTrue(ReaderAnnotation(id = "t", bookId = "b", audioPositionMs = 12_000L).opensInPlayer)
        assertFalse(ReaderAnnotation(id = "e", bookId = "b").opensInPlayer)
    }

    @Test
    fun switchingReadingOffPreservesTheSelectedShelf() {
        assertEquals(MediaFilter.ALL, effectiveLibraryMedia(MediaFilter.COMICS, readingEnabled = false))
        assertEquals(MediaFilter.ALL, effectiveLibraryMedia(MediaFilter.EBOOKS, readingEnabled = false))
        assertEquals(MediaFilter.AUDIOBOOKS, effectiveLibraryMedia(MediaFilter.AUDIOBOOKS, readingEnabled = false))
        assertEquals(StatusFilter.LISTENING, effectiveLibraryStatus(StatusFilter.READING, readingEnabled = false))

        assertEquals(MediaFilter.COMICS, effectiveLibraryMedia(MediaFilter.COMICS, readingEnabled = true))
        assertEquals(StatusFilter.READING, effectiveLibraryStatus(StatusFilter.READING, readingEnabled = true))
    }

    @Test
    fun readingControlsAreOfferedOnlyWhenReadingIsOn() {
        assertFalse(MediaFilter.COMICS in availableLibraryMedia(false))
        assertFalse(MediaFilter.EBOOKS in availableLibraryMedia(false))
        assertFalse(StatusFilter.READING in availableLibraryStatuses(false))
        assertEquals(MediaFilter.entries, availableLibraryMedia(true))
        assertEquals(StatusFilter.entries, availableLibraryStatuses(true))
    }
}
