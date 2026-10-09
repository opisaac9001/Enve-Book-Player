package com.enve.app.data.hardcover

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
        assertTrue(hardcoverRetryDelaySeconds(429, "2") == 2L)
        assertTrue(hardcoverRetryDelaySeconds(429, "60") == null)
        assertTrue(hardcoverRetryDelaySeconds(403, "2") == null)
    }
}
