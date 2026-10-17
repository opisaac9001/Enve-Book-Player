package com.enve.app.playback

import androidx.media3.common.MimeTypes
import com.enve.core.data.remote.ConnectionScope
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

class ConnectionStreamRoutingTest {
    private val server = MockWebServer()
    private val observedConnections = mutableListOf<String?>()

    @Before
    fun setUp() = server.start()

    @After
    fun tearDown() = server.shutdown()

    private fun client(): OkHttpClient {
        val base = OkHttpClient.Builder()
            .addInterceptor { chain ->
                synchronized(observedConnections) { observedConnections += ConnectionScope.getConnectionId() }
                chain.proceed(chain.request())
            }
            .build()
        return base.newBuilder()
            .apply { interceptors().add(0, StreamConnectionInterceptor) }
            .build()
    }

    @Test
    fun tagsOnlyRemoteStreamsWithoutAnExistingFragment() {
        assertEquals(
            "https://orbit.test/api/v1/audiobooks/1/assets/a/content#enve-connection=conn-1",
            connectionStreamUrl("https://orbit.test/api/v1/audiobooks/1/assets/a/content", "conn-1"),
        )
        assertEquals("file:///data/track.m4b", connectionStreamUrl("file:///data/track.m4b", "conn-1"))
        assertEquals("https://feed.test/a.mp3#enve-public-stream", connectionStreamUrl("https://feed.test/a.mp3#enve-public-stream", "conn-1"))
        assertEquals("https://orbit.test/a", connectionStreamUrl("https://orbit.test/a", null))
        assertEquals("https://orbit.test/a", connectionStreamUrl("https://orbit.test/a", " "))
    }

    @Test
    fun connectionIdRoundTripsThroughTheRawFragment() {
        val tagged = connectionStreamUrl("http://orbit.test/a", "id+with/odd%chars")
        assertEquals("id+with/odd%chars", streamConnectionId(tagged.substringAfter('#')))
        assertNull(streamConnectionId("enve-public-stream"))
        assertNull(streamConnectionId(null))
    }

    @Test
    fun interceptorScopesAuthLayerAndStripsMarkerHeader() {
        server.enqueue(MockResponse().setBody("audio"))
        val request = Request.Builder()
            .url(server.url("/content"))
            .header(STREAM_CONNECTION_HEADER, "conn-orbit")
            .build()

        ConnectionScope.withConnectionId("conn-other") {
            client().newCall(request).execute().use { assertEquals(200, it.code) }
            assertEquals("conn-other", ConnectionScope.getConnectionId())
        }

        assertEquals(listOf<String?>("conn-orbit"), observedConnections)
        assertNull(server.takeRequest(5, TimeUnit.SECONDS)!!.getHeader(STREAM_CONNECTION_HEADER))
    }

    @Test
    fun interceptorScopesAsyncCallsOnDispatcherThreads() {
        server.enqueue(MockResponse().setBody("audio"))
        val done = CompletableFuture<Int>()
        val request = Request.Builder()
            .url(server.url("/content"))
            .header(STREAM_CONNECTION_HEADER, "conn-async")
            .build()
        client().newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                done.completeExceptionally(e)
            }

            override fun onResponse(call: Call, response: Response) {
                response.use { done.complete(it.code) }
            }
        })

        assertEquals(200, done.get(5, TimeUnit.SECONDS))
        assertEquals(listOf<String?>("conn-async"), observedConnections)
    }

    @Test
    fun untaggedRequestsKeepTheCallerScope() {
        server.enqueue(MockResponse().setBody("audio"))
        ConnectionScope.withConnectionId("caller") {
            client().newCall(Request.Builder().url(server.url("/cover")).build()).execute().close()
        }
        assertEquals(listOf<String?>("caller"), observedConnections)
    }

    @Test
    fun providerFormatWinsOverOpaqueContentUrl() {
        assertEquals(MimeTypes.AUDIO_MPEG, AudioPlaybackManager.guessMimeType("https://orbit.test/assets/a/content"))
        assertEquals(MimeTypes.AUDIO_MP4, AudioPlaybackManager.mimeTypeForAudioFormat("M4B"))
        assertEquals(MimeTypes.AUDIO_OGG, AudioPlaybackManager.mimeTypeForAudioFormat("opus"))
        assertEquals(MimeTypes.AUDIO_FLAC, AudioPlaybackManager.mimeTypeForAudioFormat(".flac"))
        assertEquals("audio/mp4", AudioPlaybackManager.mimeTypeForAudioFormat("audio/mp4"))
        assertNull(AudioPlaybackManager.mimeTypeForAudioFormat("aax"))
        assertNull(AudioPlaybackManager.mimeTypeForAudioFormat(null))
        assertEquals(MimeTypes.AUDIO_MP4, AudioPlaybackManager.guessMimeType("https://x.test/book.m4b?token=1"))
    }
}
