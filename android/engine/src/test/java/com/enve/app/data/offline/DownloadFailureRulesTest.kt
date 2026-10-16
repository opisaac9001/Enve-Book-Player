package com.enve.app.data.offline

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.SocketTimeoutException

class DownloadFailureRulesTest {
    @Test
    fun clientErrorsAndUnsupportedBooksAreTerminal() {
        listOf(400, 401, 403, 404, 410).forEach { code ->
            assertFalse("HTTP $code", isRetryableDownloadFailure(TrackDownloadHttpException(code)))
        }
        assertFalse(isRetryableDownloadFailure(UnsupportedDownloadException("No resolver")))
    }

    @Test
    fun transientFailuresAreRetryable() {
        listOf(408, 429, 500, 502, 503).forEach { code ->
            assertTrue("HTTP $code", isRetryableDownloadFailure(TrackDownloadHttpException(code)))
        }
        assertTrue(isRetryableDownloadFailure(SocketTimeoutException()))
        assertTrue(isRetryableDownloadFailure(IOException("reset")))
        assertTrue(isRetryableDownloadFailure(TrackDownloadIntegrityException("short")))
    }

    @Test
    fun contentRangeIsParsed() {
        assertEquals(100L, contentRangeStart("bytes 100-999/1000"))
        assertEquals(1000L, contentRangeTotal("bytes 100-999/1000"))
        assertNull(contentRangeTotal("bytes 100-999/*"))
        assertNull(contentRangeStart(null))
    }

    @Test
    fun onlyStrongValidatorsAreUsedForIfRange() {
        assertEquals("\"abc\"", strongResumeValidator("\"abc\"", "Tue, 01 Oct 2026 10:00:00 GMT"))
        assertEquals("Tue, 01 Oct 2026 10:00:00 GMT", strongResumeValidator("W/\"abc\"", "Tue, 01 Oct 2026 10:00:00 GMT"))
        assertNull(strongResumeValidator("W/\"abc\"", null))
        assertNull(strongResumeValidator(null, " "))
    }
}
