package com.enve.core.data.local

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CachedBookReadStatusTest {

    private fun grimmoryBook(status: String?, progress: Float = 0.25f) = Book(
        id = "42",
        title = "Status fixture",
        source = BookSource.GRIMMORY,
        mediaType = AppMediaType.EBOOK,
        readProgress = progress,
        epubProgress = progress,
        serverReadStatus = status,
    )

    @Test
    fun readStatusSuppressesResidualProgress() {
        val cached = grimmoryBook("READ").toCachedBook(nowMs = 1L)

        assertTrue(cached.isFinished)
        assertFalse(cached.inProgress)
        assertEquals("READ", cached.toBook().serverReadStatus)
    }

    @Test
    fun pausedStatusSuppressesResidualProgressWithoutFinishing() {
        val cached = grimmoryBook("PAUSED").toCachedBook(nowMs = 1L)

        assertFalse(cached.isFinished)
        assertFalse(cached.inProgress)
    }

    @Test
    fun readingStatusAllowsResidualProgress() {
        val cached = grimmoryBook("RE_READING").toCachedBook(nowMs = 1L)

        assertFalse(cached.isFinished)
        assertTrue(cached.inProgress)
    }

    @Test
    fun nonGrimmoryStatusAliasDoesNotCountAsReading() {
        val cached = grimmoryBook("IN_PROGRESS").toCachedBook(nowMs = 1L)

        assertFalse(cached.isFinished)
        assertFalse(cached.inProgress)
    }

    @Test
    fun unknownStatusKeepsLegacyProgressFallback() {
        val cached = grimmoryBook(null).toCachedBook(nowMs = 1L)

        assertTrue(cached.inProgress)
    }
}
