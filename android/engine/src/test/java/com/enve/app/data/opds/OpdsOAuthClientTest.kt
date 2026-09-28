package com.enve.app.data.opds

import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.IOException
import java.util.concurrent.atomic.AtomicReference

class OpdsOAuthClientTest {

    private val tokenUrl = "https://opds.example.com/oauth/token"

    @Test
    fun a_token_grant_never_runs_on_the_thread_that_asked_for_it() = runBlocking {
        val callThread = AtomicReference<String>()
        val client = OpdsOAuthClient(
            clientAnswering { chain ->
                callThread.set(Thread.currentThread().name)
                json(chain, """{"access_token":"abc","token_type":"Bearer"}""")
            },
        )

        val token = client.password(tokenUrl, "reader", "hunter2")

        assertEquals("abc", token?.accessToken)
        assertNotNull(callThread.get())
        assertNotEquals(Thread.currentThread().name, callThread.get())
    }

    @Test
    fun a_network_failure_is_a_refused_sign_in_rather_than_a_crash() = runBlocking {
        val client = OpdsOAuthClient(clientAnswering { throw IOException("unreachable") })

        assertNull(client.password(tokenUrl, "reader", "hunter2"))
        assertNull(client.passwordBlocking(tokenUrl, "reader", "hunter2"))
        assertNull(client.refreshBlocking(tokenUrl, "refresh-token"))
    }

    @Test
    fun a_rejected_grant_is_refused_without_reading_a_token_out_of_the_error_body() = runBlocking {
        val client = OpdsOAuthClient(
            clientAnswering { chain ->
                json(chain, """{"access_token":"abc"}""", code = 401)
            },
        )

        assertNull(client.password(tokenUrl, "reader", "hunter2"))
        assertNull(client.refreshBlocking(tokenUrl, "refresh-token"))
    }

    @Test
    fun a_token_endpoint_that_is_not_http_is_never_called() = runBlocking {
        val called = AtomicReference<String>()
        val client = OpdsOAuthClient(
            clientAnswering { chain ->
                called.set(chain.request().url.toString())
                json(chain, """{"access_token":"abc"}""")
            },
        )

        assertNull(client.password("enve://opds-auth", "reader", "hunter2"))
        assertNull(client.refreshBlocking("javascript:alert(1)", "refresh-token"))
        assertNull(called.get())
    }

    private fun clientAnswering(interceptor: Interceptor): OkHttpClient =
        OkHttpClient.Builder().addInterceptor(interceptor).build()

    private fun json(chain: Interceptor.Chain, body: String, code: Int = 200): Response =
        Response.Builder()
            .request(chain.request())
            .protocol(Protocol.HTTP_1_1)
            .code(code)
            .message(if (code == 200) "OK" else "Unauthorized")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
}
