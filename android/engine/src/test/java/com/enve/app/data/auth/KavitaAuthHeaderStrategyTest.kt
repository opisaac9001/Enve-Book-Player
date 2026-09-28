package com.enve.app.data.auth

import com.enve.core.data.remote.AuthHeaderContext
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class KavitaAuthHeaderStrategyTest {
    private val strategy = KavitaAuthHeaderStrategy()

    @Test
    fun uses_bearer_for_a_jwt() {
        val signed = sign("header.payload.signature")

        assertEquals("Bearer header.payload.signature", signed.header("Authorization"))
        assertNull(signed.header("X-API-Key"))
    }

    @Test
    fun uses_api_key_header_for_an_auth_key() {
        val signed = sign("kavita-auth-key")

        assertEquals("kavita-auth-key", signed.header("X-API-Key"))
        assertNull(signed.header("Authorization"))
    }

    private fun sign(token: String): Request {
        val request = Request.Builder().url("https://kavita.example.invalid/api/image/series-cover?seriesId=3").build()
        return strategy.apply(AuthHeaderContext(request, request.newBuilder(), token, "reader"))
    }
}
