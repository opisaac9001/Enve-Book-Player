package com.enve.core.data.remote

import okhttp3.Credentials
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AuthHeaderStrategyTest {

    private val strategy = BasicAuthHeaderStrategy()

    @Test
    fun basic_strategy_omits_authorization_when_credentials_are_blank() {
        val request = baseRequest()

        val signed = strategy.apply(
            AuthHeaderContext(
                original = request,
                builder = request.newBuilder(),
                token = "",
                username = "",
            ),
        )

        assertNull(signed.header("Authorization"))
    }

    @Test
    fun basic_strategy_preserves_explicit_authorization_header() {
        val request = baseRequest()
            .newBuilder()
            .header("Authorization", "Basic explicit")
            .build()

        val signed = strategy.apply(
            AuthHeaderContext(
                original = request,
                builder = request.newBuilder(),
                token = "password",
                username = "user",
            ),
        )

        assertEquals("Basic explicit", signed.header("Authorization"))
    }

    @Test
    fun basic_strategy_adds_basic_header_when_credentials_exist() {
        val request = baseRequest()

        val signed = strategy.apply(
            AuthHeaderContext(
                original = request,
                builder = request.newBuilder(),
                token = "password",
                username = "user",
            ),
        )

        assertEquals(Credentials.basic("user", "password"), signed.header("Authorization"))
    }

    private fun baseRequest(): Request =
        Request.Builder()
            .url("https://opds.example.com/catalog")
            .build()
}
