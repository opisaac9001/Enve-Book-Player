package com.enve.app.di

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class HttpLoggingRedactionTest {

    @Test
    fun redacts_sensitive_headers() {
        assertEquals(
            "Authorization: [redacted]",
            redactSensitiveHttpLogMessage("Authorization: Bearer secret-token"),
        )
        assertEquals(
            "X-Plex-Token: [redacted]",
            redactSensitiveHttpLogMessage("X-Plex-Token: secret-token"),
        )
    }

    @Test
    fun redacts_token_query_parameters() {
        val redacted = redactSensitiveHttpLogMessage(
            "--> GET https://plex.example/library?X-Plex-Token=secret-token&limit=50",
        )

        assertEquals(
            "--> GET https://plex.example/library?X-Plex-Token=[redacted]&limit=50",
            redacted,
        )
        assertFalse(redacted.contains("secret-token"))
    }
}
