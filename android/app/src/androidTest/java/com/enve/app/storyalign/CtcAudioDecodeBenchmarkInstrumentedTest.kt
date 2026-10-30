package com.enve.app.storyalign

import android.os.Process
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.storyalign.audio.AudioDecoder
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class CtcAudioDecodeBenchmarkInstrumentedTest {
    @Test
    fun decodeProvidedAudio() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("ctcAudio") != null)
        val audio = File(checkNotNull(args.getString("ctcAudio")))
        val output = File(checkNotNull(args.getString("ctcOutputDirectory")))
        assertTrue(audio.isFile)
        assertTrue(output.isDirectory || output.mkdirs())
        var samples = 0L
        val digest = MessageDigest.getInstance("SHA-256")
        val cpuStarted = Process.getElapsedCpuTime()
        val started = SystemClock.elapsedRealtime()
        AudioDecoder().decode(audio.absolutePath) { chunk, _ ->
            samples += chunk.size
            val bytes = ByteBuffer.allocate(chunk.size * 4).order(ByteOrder.LITTLE_ENDIAN)
            bytes.asFloatBuffer().put(chunk)
            digest.update(bytes.array())
        }
        val report = JSONObject()
            .put("wallMillis", SystemClock.elapsedRealtime() - started)
            .put("cpuMillis", Process.getElapsedCpuTime() - cpuStarted)
            .put("samples", samples)
            .put("audioSeconds", samples / 16_000.0)
            .put("pcmSHA256", digest.digest().joinToString("") { "%02x".format(it) })
        File(output, "decode-benchmark.json").writeText(report.toString(2))
        assertTrue(samples > 0)
    }
}
