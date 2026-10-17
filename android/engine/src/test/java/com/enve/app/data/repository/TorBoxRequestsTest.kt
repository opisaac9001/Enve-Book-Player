package com.enve.app.data.repository

import com.enve.app.data.remote.dto.TorBoxListResponseDto
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class TorBoxRequestsTest {
    @Test fun validEmptyListDiffersFromFailedRequest() {
        assertTrue(TorBoxListResponseDto(success = true, data = emptyList()).requireTorBoxList().isEmpty())
        assertTrue(TorBoxListResponseDto(error = "ITEM_NOT_FOUND").requireTorBoxList().isEmpty())
        for (response in listOf(TorBoxListResponseDto(), TorBoxListResponseDto(success = true))) {
            assertThrows(TorBoxRequestException::class.java) { response.requireTorBoxList() }
        }
    }

    @Test fun authenticationFailureDoesNotExposeServerDetailsOrRetry() {
        val error = assertThrows(TorBoxRequestException::class.java) {
            TorBoxListResponseDto(error = "BAD_TOKEN", detail = "private credentials").requireTorBoxList()
        }
        assertEquals(401, error.status)
        assertFalse(error.message!!.contains("private"))
        assertNull(torBoxRetryDelay(error, 0))
    }

    @Test fun transientRetriesAreBoundedAndRespectRetryAfter() {
        assertEquals(500L, torBoxRetryDelay(IOException(), 0))
        assertEquals(1000L, torBoxRetryDelay(TorBoxRequestException(503), 1))
        assertNull(torBoxRetryDelay(IOException(), 2))
        assertEquals(2000L, torBoxRetryDelay(TorBoxRequestException(429, "2"), 0))
        assertNull(torBoxRetryDelay(TorBoxRequestException(429, "60"), 0))
        assertEquals(1000L, torBoxRetryDelay(TorBoxRequestException(429, "Thu, 01 Jan 1970 00:00:01 GMT"), 0, 0))
    }

    @Test fun cancellationIsNeverRetried() = runBlocking {
        var calls = 0
        try {
            retryTorBoxRequest<Unit> { calls++; throw CancellationException() }
            fail("Expected cancellation")
        } catch (_: CancellationException) {
            assertEquals(1, calls)
        }
    }

    @Test fun retryRecoversAfterRateLimit() = runBlocking {
        var calls = 0
        assertEquals("loaded", retryTorBoxRequest {
            if (calls++ == 0) throw TorBoxRequestException(429, "0")
            "loaded"
        })
        assertEquals(2, calls)
    }
}
