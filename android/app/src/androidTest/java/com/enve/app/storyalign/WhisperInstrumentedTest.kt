package com.enve.app.storyalign

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.storyalign.transcribe.WhisperContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

@RunWith(AndroidJUnit4::class)
class WhisperInstrumentedTest {

    @Test
    fun transcribesRealSpeech() {
        val model = File("/data/local/tmp/ggml-tiny.en.bin")
        val wav = File("/data/local/tmp/speech.wav")
        assumeTrue("push model + speech.wav to /data/local/tmp first", model.exists() && wav.exists())

        val pcm = readWav16kMonoFloat(wav)
        assertTrue("audio too short: ${pcm.size}", pcm.size > 16_000)

        val ctx = WhisperContext.fromFile(model.absolutePath)
        try {
            val rc = ctx.transcribe(pcm, "en", 4)
            assertEquals("whisper_full rc", 0, rc)

            val segments = ctx.segmentCount()
            assertTrue("no segments", segments > 0)

            val transcript = buildString {
                for (s in 0 until segments) append(ctx.segmentText(s))
            }.lowercase()
            assertTrue("transcript did not contain 'fox': '$transcript'", transcript.contains("fox"))

            var lastEnd = -1.0
            for (s in 0 until segments) {
                for (t in 0 until ctx.tokenCount(s)) {
                    val t0 = ctx.tokenStartSec(s, t)
                    val t1 = ctx.tokenEndSec(s, t)
                    assertTrue("token t1 < t0", t1 >= t0 - 1e-6)
                    assertTrue("token times decreased", t0 >= lastEnd - 1.0)
                    lastEnd = t1
                }
            }
        } finally {
            ctx.release()
        }
    }

    private fun readWav16kMonoFloat(f: File): FloatArray {
        val bytes = f.readBytes()
        var i = 12
        var dataOffset = -1
        var dataLen = 0
        while (i + 8 <= bytes.size) {
            val id = String(bytes, i, 4, Charsets.US_ASCII)
            val sz = ByteBuffer.wrap(bytes, i + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
            if (id == "data") {
                dataOffset = i + 8
                dataLen = sz.coerceAtMost(bytes.size - dataOffset)
                break
            }
            i += 8 + sz + (sz and 1)
        }
        require(dataOffset >= 0) { "no data chunk in WAV" }
        val n = dataLen / 2
        val out = FloatArray(n)
        val bb = ByteBuffer.wrap(bytes, dataOffset, dataLen).order(ByteOrder.LITTLE_ENDIAN)
        for (k in 0 until n) out[k] = bb.short / 32768f
        return out
    }
}
