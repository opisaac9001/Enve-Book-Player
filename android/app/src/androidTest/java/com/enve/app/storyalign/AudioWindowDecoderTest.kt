package com.enve.app.storyalign

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.storyalign.audio.AudioWindowDecoder
import com.enve.core.data.remote.ConnectionScope
import fi.iki.elonen.NanoHTTPD
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.sin
import kotlin.math.sqrt

@RunWith(AndroidJUnit4::class)
class AudioWindowDecoderTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val client = OkHttpClient.Builder().addInterceptor { chain ->
        chain.proceed(chain.request().newBuilder()
            .header("X-Fixture-Connection", ConnectionScope.getConnectionId().orEmpty()).build())
    }.build()

    @Test fun localWindowStartsAtTheRequestedAudioPosition() = runBlocking {
        val file = File(context.cacheDir, "window-${UUID.randomUUID()}.wav")
        file.writeBytes(wave(10))
        try {
            val samples = withContext(Dispatchers.IO) { AudioWindowDecoder(context, client).decode(file.path, null, 3.0, 1.2) }
            assertTrue(kotlin.math.abs(samples.size - 19_200) <= 256)
            assertTrue(energy(samples) > 0.2)
        } finally { file.delete() }
    }

    @Test fun streamedWindowUsesBoundedRangesAndItsOwnConnection() = runBlocking {
        Fixture(wave(600)).use { server ->
            val samples = withContext(Dispatchers.IO) {
                AudioWindowDecoder(context, client).decode(server.url, "fixture-connection", 120.0, 1.2, "\"fixture\"")
            }
            assertTrue(kotlin.math.abs(samples.size - 19_200) <= 256)
            assertTrue(energy(samples) > 0.2)
            assertTrue(server.served.get() < server.data.size / 4)
            assertTrue(server.served.get() > 0)
        }
    }

    @Test fun aServerIgnoringRangesCannotTriggerAFullBookDownload() = runBlocking {
        Fixture(wave(10), ignoreRange = true).use { server ->
            val failure = runCatching {
                withContext(Dispatchers.IO) { AudioWindowDecoder(context, client).decode(server.url, "fixture-connection", 1.0, 1.0) }
            }.exceptionOrNull()
            assertTrue(failure is IOException)
        }
    }

    @Test fun cancellationClosesAStalledRemoteRead() = runBlocking {
        Fixture(wave(10), stall = true).use { server ->
            val decoding = launch(Dispatchers.IO) {
                AudioWindowDecoder(context, client).decode(server.url, "fixture-connection", 1.0, 1.0)
            }
            withTimeout(5_000) { while (server.requests.get() == 0L) delay(20) }
            withTimeout(2_000) { decoding.cancel(); decoding.join() }
            assertTrue(decoding.isCancelled)
        }
    }

    private fun energy(samples: FloatArray): Double = sqrt(samples.sumOf { (it * it).toDouble() } / samples.size)

    private fun wave(seconds: Int): ByteArray {
        val rate = 16_000
        val count = seconds * rate
        val buffer = ByteBuffer.allocate(44 + count * 2).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray()).putInt(36 + count * 2).put("WAVEfmt ".toByteArray()).putInt(16)
        buffer.putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
        buffer.put("data".toByteArray()).putInt(count * 2)
        repeat(count) { index ->
            buffer.putShort(if (index < rate * 2) 0 else (sin(index * 2 * Math.PI * 440 / rate) * 16_000).toInt().toShort())
        }
        return buffer.array()
    }

    class Fixture(val data: ByteArray, val ignoreRange: Boolean = false, val stall: Boolean = false) : NanoHTTPD("127.0.0.1", 0), AutoCloseable {
        val served = AtomicLong()
        val requests = AtomicLong()
        val url get() = "http://127.0.0.1:$listeningPort/audio.wav"
        init { start(SOCKET_READ_TIMEOUT, false) }

        override fun serve(session: IHTTPSession): Response {
            requests.incrementAndGet()
            if (stall) Thread.sleep(5_000)
            if (session.headers["x-fixture-connection"] != "fixture-connection")
                return newFixedLengthResponse(Response.Status.FORBIDDEN, "text/plain", "")
            if (session.method == Method.HEAD) return newFixedLengthResponse(Response.Status.OK, "audio/wav", "").apply {
                addHeader("ETag", "\"fixture\"")
            }
            val range = session.headers["range"]?.removePrefix("bytes=")?.split('-')
            val start = range?.firstOrNull()?.toIntOrNull() ?: 0
            val end = minOf(range?.lastOrNull()?.toIntOrNull() ?: data.lastIndex, data.lastIndex)
            if (start > end) return newFixedLengthResponse(Response.Status.RANGE_NOT_SATISFIABLE, "text/plain", "")
            if (ignoreRange) return newFixedLengthResponse(Response.Status.OK, "audio/wav", ByteArrayInputStream(data), data.size.toLong())
            val count = end - start + 1
            served.addAndGet(count.toLong())
            return newFixedLengthResponse(Response.Status.PARTIAL_CONTENT, "audio/wav", ByteArrayInputStream(data, start, count), count.toLong()).apply {
                addHeader("Accept-Ranges", "bytes")
                addHeader("Content-Range", "bytes $start-$end/${this@Fixture.data.size}")
                addHeader("ETag", "\"fixture\"")
            }
        }
        override fun close() { stop() }
    }
}
