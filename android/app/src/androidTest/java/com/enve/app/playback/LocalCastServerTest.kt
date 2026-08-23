package com.enve.app.playback

import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LocalCastServerTest {
    private val receiverOrigin = "https://receiver.example"
    private lateinit var server: LocalCastServer
    private lateinit var source: File

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        server = LocalCastServer(context)
        source = File(context.cacheDir, "cast-server-test.mp3")
        source.writeBytes(ByteArray(1_024) { it.toByte() })
    }

    @After
    fun tearDown() {
        server.stop()
        source.delete()
    }

    @Test
    fun servesLocalFileToLanClientWithRangeAndCors() {
        assertTrue(server.start())
        val url = requireNotNull(server.urlFor(Uri.fromFile(source)))
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.setRequestProperty("Range", "bytes=100-199")
        connection.setRequestProperty("Origin", receiverOrigin)

        assertEquals(HttpURLConnection.HTTP_PARTIAL, connection.responseCode)
        assertEquals("bytes 100-199/1024", connection.getHeaderField("Content-Range"))
        assertEquals("bytes", connection.getHeaderField("Accept-Ranges"))
        assertEquals(receiverOrigin, connection.getHeaderField("Access-Control-Allow-Origin"))
        assertEquals("Origin", connection.getHeaderField("Vary"))
        assertEquals(
            "Range, Content-Type, Accept-Encoding",
            connection.getHeaderField("Access-Control-Allow-Headers"),
        )
        assertArrayEquals(source.readBytes().copyOfRange(100, 200), connection.inputStream.readBytes())
        connection.disconnect()
    }

    @Test
    fun acceptsReceiverCorsPreflight() {
        assertTrue(server.start())
        val url = requireNotNull(server.urlFor(Uri.fromFile(source)))
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = "OPTIONS"
        connection.setRequestProperty("Origin", receiverOrigin)
        connection.setRequestProperty(
            "Access-Control-Request-Headers",
            "content-type, accept-encoding, range",
        )

        assertEquals(HttpURLConnection.HTTP_NO_CONTENT, connection.responseCode)
        assertEquals(receiverOrigin, connection.getHeaderField("Access-Control-Allow-Origin"))
        assertEquals("GET, HEAD, OPTIONS", connection.getHeaderField("Access-Control-Allow-Methods"))
        assertEquals(
            "Range, Content-Type, Accept-Encoding",
            connection.getHeaderField("Access-Control-Allow-Headers"),
        )
        connection.disconnect()
    }
}
