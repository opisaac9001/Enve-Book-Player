package com.enve.core.data.remote

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DynamicUrlRewriterTest {

    @Test
    fun isPlaceholder_matches_retrofit_placeholder_hosts_only() {
        assertTrue(DynamicUrlRewriter.isPlaceholder("http://localhost/api/books".toHttpUrl()))
        assertTrue(DynamicUrlRewriter.isPlaceholder("http://127.0.0.1/api/books".toHttpUrl()))
        assertFalse(DynamicUrlRewriter.isPlaceholder("https://library.example.com/api/books".toHttpUrl()))
    }

    @Test
    fun normalizedBaseUrl_adds_https_and_trims_control_characters() {
        val url = DynamicUrlRewriter.normalizedBaseUrl("  \u0000library.example.com/base///  ")

        assertEquals("https", url?.scheme)
        assertEquals("library.example.com", url?.host)
        assertEquals("/base///", url?.encodedPath)
    }

    @Test
    fun normalizedBaseUrl_recovers_nested_protocol_prefix() {
        val url = DynamicUrlRewriter.normalizedBaseUrl("https://https://real.example.com")

        assertEquals("https://real.example.com/", url.toString())
    }

    @Test
    fun normalizedBaseUrl_keeps_first_complete_url_from_concatenated_duplicate() {
        val url = DynamicUrlRewriter.normalizedBaseUrl("http://10.0.0.2:8080http://10.0.0.2:8080")

        assertEquals("http://10.0.0.2:8080/", url.toString())
    }

    @Test
    fun normalizedBaseUrl_returns_null_for_invalid_server_url() {
        assertNull(DynamicUrlRewriter.normalizedBaseUrl("https://"))
    }

    @Test
    fun rewritePlaceholder_preserves_base_path_request_path_and_query() {
        val original = "http://localhost/api/v1/books?library=main&sort=added".toHttpUrl()
        val base = "https://library.example.com/proxy/root/".toHttpUrl()

        val rewritten = DynamicUrlRewriter.rewritePlaceholder(original, base)

        assertEquals("https://library.example.com/proxy/root/api/v1/books?library=main&sort=added", rewritten.toString())
    }
}
