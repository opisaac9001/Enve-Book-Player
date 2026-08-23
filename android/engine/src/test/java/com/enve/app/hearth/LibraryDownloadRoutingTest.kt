package com.enve.app.hearth

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryDownloadRoutingTest {

    @Test
    fun `storyteller readaloud ebook uses its single file package`() {
        val book = Book(
            id = "seamage",
            title = "Seamage",
            source = BookSource.STORYTELLER,
            mediaType = AppMediaType.EBOOK,
            readAlongAvailable = true,
            hasAudio = true,
            hasEbook = true,
        )

        assertFalse(book.usesOfflineAudioDownload())
    }

    @Test
    fun `pure audiobook uses audio offline downloads`() {
        val book = Book(
            id = "audio",
            title = "Audio",
            mediaType = AppMediaType.AUDIOBOOK,
        )

        assertTrue(book.usesOfflineAudioDownload())
    }

    @Test
    fun `storyteller audiobook without readaloud uses audio offline downloads`() {
        val book = Book(
            id = "storyteller-audio",
            title = "Storyteller Audio",
            source = BookSource.STORYTELLER,
            mediaType = AppMediaType.AUDIOBOOK,
            hasAudio = true,
        )

        assertTrue(book.usesOfflineAudioDownload())
    }

    @Test
    fun `plain ebook stays on single file offline downloads`() {
        val book = Book(
            id = "ebook",
            title = "Ebook",
            mediaType = AppMediaType.EBOOK,
            source = BookSource.KOMGA,
            hasAudio = false,
            readAlongAvailable = false,
        )

        assertFalse(book.usesOfflineAudioDownload())
    }
}
