package com.enve.hearth

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkUnreadConfirmationTest {
    private val audiobook = Book(id = "a", title = "Audio", mediaType = AppMediaType.AUDIOBOOK, duration = 36_000)
    private val ebook = Book(id = "e", title = "Ebook", mediaType = AppMediaType.EBOOK)

    @Test
    fun audiobookNeedsConfirmationOnlyAfterTwoMinutes() {
        assertFalse(audiobook.copy(currentTime = 0).needsUnreadConfirmation())
        assertFalse(audiobook.copy(currentTime = 120).needsUnreadConfirmation())
        assertTrue(audiobook.copy(currentTime = 121).needsUnreadConfirmation())
    }

    @Test
    fun audiobookWithOnlyAPercentageUsesItsDuration() {
        assertFalse(audiobook.copy(readProgress = 0.003f).needsUnreadConfirmation())
        assertTrue(audiobook.copy(readProgress = 0.004f).needsUnreadConfirmation())
    }

    @Test
    fun podcastFollowsTheListeningThreshold() {
        val episode = audiobook.copy(mediaType = AppMediaType.PODCAST)
        assertFalse(episode.copy(currentTime = 90).needsUnreadConfirmation())
        assertTrue(episode.copy(currentTime = 600).needsUnreadConfirmation())
    }

    @Test
    fun ebookNeedsConfirmationOnlyAboveOnePercent() {
        assertFalse(ebook.needsUnreadConfirmation())
        assertFalse(ebook.copy(readProgress = 0.01f).needsUnreadConfirmation())
        assertTrue(ebook.copy(readProgress = 0.011f).needsUnreadConfirmation())
        assertTrue(ebook.copy(readProgress = 0f, epubProgress = 0.2f).needsUnreadConfirmation())
    }

    @Test
    fun readAlongEbookCountsListeningTime() {
        assertTrue(ebook.copy(readProgress = 0.005f, currentTime = 300).needsUnreadConfirmation())
    }

    @Test
    fun finishedBookAlwaysNeedsConfirmation() {
        assertTrue(ebook.copy(isFinished = true).needsUnreadConfirmation())
        assertTrue(audiobook.copy(isFinished = true).needsUnreadConfirmation())
    }
}
