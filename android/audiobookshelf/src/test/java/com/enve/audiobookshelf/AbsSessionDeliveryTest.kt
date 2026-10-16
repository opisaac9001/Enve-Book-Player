package com.enve.audiobookshelf

import com.enve.audiobookshelf.listening.AbsPlaybackSessionHttpException
import com.enve.audiobookshelf.listening.AbsSessionDelivery
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.ConnectException
import java.net.ServerSocket
import java.util.concurrent.TimeUnit

class AbsSessionDeliveryTest {
    private fun failureFrom(configure: (MockWebServer) -> Unit): Throwable {
        val server = MockWebServer()
        configure(server)
        server.start()
        val client = OkHttpClient.Builder().readTimeout(300, TimeUnit.MILLISECONDS).build()
        return try {
            runCatching { client.newCall(Request.Builder().url(server.url("/api/session/s/sync")).build()).execute().close() }
                .exceptionOrNull()!!
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun readTimeoutAfterTheRequestWasSentMayHaveApplied() {
        val error = failureFrom { it.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE)) }
        assertTrue(error.toString(), AbsSessionDelivery.mayHaveApplied(error))
    }

    @Test
    fun retriedConnectFailureAfterADeliveredAttemptMayHaveApplied() {
        val delivered = IOException("unexpected end of stream")
        val error = ConnectException("Failed to connect").apply { addSuppressed(delivered) }
        assertTrue(AbsSessionDelivery.mayHaveApplied(error))
        assertFalse(AbsSessionDelivery.mayHaveApplied(ConnectException("first").apply { addSuppressed(ConnectException("second")) }))
    }

    @Test
    fun connectionDroppedAfterTheRequestMayHaveApplied() {
        val error = failureFrom { it.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST)) }
        assertTrue(error.toString(), AbsSessionDelivery.mayHaveApplied(error))
    }

    @Test
    fun refusedConnectionNeverReachedTheServer() {
        val port = ServerSocket(0).use { it.localPort }
        val error = runCatching {
            OkHttpClient().newCall(Request.Builder().url("http://127.0.0.1:$port/api/session/s/sync").build()).execute().close()
        }.exceptionOrNull()!!
        assertFalse(error.toString(), AbsSessionDelivery.mayHaveApplied(error))
    }

    @Test
    fun serverErrorsAreAmbiguousButRejectionsAreNot() {
        assertTrue(AbsSessionDelivery.mayHaveApplied(AbsPlaybackSessionHttpException(500, "sync")))
        assertTrue(AbsSessionDelivery.mayHaveApplied(AbsPlaybackSessionHttpException(503, "close")))
        assertFalse(AbsSessionDelivery.mayHaveApplied(AbsPlaybackSessionHttpException(404, "sync")))
        assertFalse(AbsSessionDelivery.mayHaveApplied(AbsPlaybackSessionHttpException(401, "sync")))
        assertFalse(AbsSessionDelivery.mayHaveApplied(IllegalStateException("Requested provider connection is unavailable")))
    }
}
