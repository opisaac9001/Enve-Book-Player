package com.enve.app.data.hardcover

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HardcoverTokenStatusTest {
    @Test fun scopedAndCapacityFailuresKeepTokenValid() {
        assertFalse(hardcoverInvalidTokenMessage(hardcoverHttpError(403, """{"error":"insufficient_scope","scope":"read:lists"}""").message.orEmpty()))
        assertFalse(hardcoverInvalidTokenMessage(hardcoverHttpError(403, """{"errors":["request_exceeds_capacity"]}""").message.orEmpty()))
        assertFalse(hardcoverInvalidTokenMessage(hardcoverHttpError(403, """{"error":"unsupported_operation"}""").message.orEmpty()))
        assertTrue(hardcoverHttpError(403, """{"error":"insufficient_scope"}""").message!!.contains("permissions"))
        assertTrue(hardcoverHttpError(429, """{"error":"Too Many Requests"}""").message!!.contains("Try again"))
        assertTrue(hardcoverInvalidTokenMessage("invalid_token"))
        assertTrue(hardcoverHttpError(401, """{"error":"invalid_token"}""").message!!.contains("invalid"))
    }

    @Test fun throttlingTimeoutsAndServerErrorsAreTransient() {
        listOf(408, 429, 500, 502, 503).forEach { status ->
            assertTrue("HTTP $status", hardcoverHttpError(status, "", retryAfterMs = 5_000) is HardcoverTransientException)
        }
        assertEquals(5_000L, (hardcoverHttpError(503, "", retryAfterMs = 5_000) as HardcoverTransientException).retryAfterMs)
        listOf(400, 401, 403, 404).forEach { status ->
            assertFalse("HTTP $status", hardcoverHttpError(status, "") is HardcoverTransientException)
        }
    }

    @Test fun accountKeyIsStableFingerprintWithoutRawToken() {
        val key = hardcoverAccountKey("secret-token")
        assertEquals(64, key.length)
        assertEquals(key, hardcoverAccountKey("secret-token"))
        assertFalse(key.contains("secret"))
        assertTrue(key != hardcoverAccountKey("other-token"))
    }
}
