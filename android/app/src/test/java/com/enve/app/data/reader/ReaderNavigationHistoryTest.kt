package com.enve.app.data.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderNavigationHistoryTest {
    @Test
    fun recordsJumpOriginsForBackNavigation() {
        val history = ReaderNavigationHistory()

        history.recordJumpOrigin("chapter-1")
        history.recordJumpOrigin("chapter-2")

        assertTrue(history.canGoBack)
        assertEquals("chapter-2", history.backTarget())
    }

    @Test
    fun ignoresBlankAndDuplicateOrigins() {
        val history = ReaderNavigationHistory()

        history.recordJumpOrigin(null)
        history.recordJumpOrigin("")
        history.recordJumpOrigin("chapter-1")
        history.recordJumpOrigin("chapter-1")
        history.commitBack("chapter-2")

        assertFalse(history.canGoBack)
        assertEquals("chapter-2", history.forwardTarget())
    }

    @Test
    fun backCommitMovesCurrentLocationToForwardStack() {
        val history = ReaderNavigationHistory()
        history.recordJumpOrigin("chapter-1")

        history.commitBack("chapter-5")

        assertFalse(history.canGoBack)
        assertTrue(history.canGoForward)
        assertEquals("chapter-5", history.forwardTarget())
    }

    @Test
    fun newJumpClearsForwardStack() {
        val history = ReaderNavigationHistory()
        history.recordJumpOrigin("chapter-1")
        history.commitBack("chapter-5")

        history.recordJumpOrigin("chapter-3")

        assertNull(history.forwardTarget())
        assertTrue(history.canGoBack)
    }

    @Test
    fun trimsOldestEntriesWhenCapacityIsExceeded() {
        val history = ReaderNavigationHistory(maxEntries = 2)

        history.recordJumpOrigin("chapter-1")
        history.recordJumpOrigin("chapter-2")
        history.recordJumpOrigin("chapter-3")
        history.commitBack("chapter-4")
        history.commitBack("chapter-3")

        assertFalse(history.canGoBack)
        assertEquals("chapter-3", history.forwardTarget())
    }
}
