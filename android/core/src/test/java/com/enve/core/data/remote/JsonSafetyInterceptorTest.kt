package com.enve.core.data.remote

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class JsonSafetyInterceptorTest {

    @Test
    fun html_mismatch_message_is_provider_neutral() {
        val message = jsonSafetyHtmlMismatchMessage(
            code = 200,
            host = "storyteller.example.com",
            location = null,
        )

        assertTrue(message.contains("correct API host"))
        assertFalse(message.contains("Grimmory"))
    }

    @Test
    fun html_mismatch_message_preserves_redirect_hint() {
        val message = jsonSafetyHtmlMismatchMessage(
            code = 302,
            host = "abs.example.com",
            location = "https://login.example.com/auth",
        )

        assertTrue(message.contains("redirected this request"))
        assertTrue(message.contains("https://login.example.com/auth"))
    }
}
