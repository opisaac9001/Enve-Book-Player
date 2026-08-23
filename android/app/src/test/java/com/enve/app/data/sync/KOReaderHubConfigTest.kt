package com.enve.app.data.sync

import com.enve.core.data.sync.KOReaderHubConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KOReaderHubConfigTest {

    @Test
    fun isConfigured_requires_all_three_fields() {
        assertFalse(KOReaderHubConfig().isConfigured)
        assertFalse(KOReaderHubConfig(serverUrl = "https://x", username = "u").isConfigured)
        assertTrue(
            KOReaderHubConfig(serverUrl = "https://x", username = "u", passwordHash = "abc")
                .isConfigured
        )
    }

    @Test
    fun baseUrl_adds_scheme_and_strips_trailing_slashes() {
        assertEquals("https://sync.koreader.rocks",
            KOReaderHubConfig(serverUrl = "sync.koreader.rocks///").baseUrl)
        assertEquals("http://10.0.0.2:8081",
            KOReaderHubConfig(serverUrl = "  http://10.0.0.2:8081/  ").baseUrl)
        assertEquals("https://a.example.com",
            KOReaderHubConfig(serverUrl = "https://a.example.com").baseUrl)
    }

    @Test
    fun baseUrl_is_null_when_blank() {
        assertNull(KOReaderHubConfig(serverUrl = "   ").baseUrl)
        assertNull(KOReaderHubConfig().baseUrl)
    }
}
