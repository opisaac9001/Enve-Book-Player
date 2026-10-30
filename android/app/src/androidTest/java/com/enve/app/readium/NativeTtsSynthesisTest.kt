package com.enve.app.readium

import android.content.Context
import android.content.Intent
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeTtsSynthesisTest {
    @Test
    fun installedSpeechEngineIsVisibleAndProducesNonSilentAudio() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        assertTrue(context.packageManager.queryIntentServices(Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0).isNotEmpty())
        val initialized = CompletableDeferred<Int>()
        val completed = CompletableDeferred<Boolean>()
        val output = File(context.cacheDir, "tts-verification-${UUID.randomUUID()}.wav")
        val engine = withContext(Dispatchers.Main) { TextToSpeech(context) { initialized.complete(it) } }
        try {
            assertEquals(TextToSpeech.SUCCESS, withTimeout(30_000) { initialized.await() })
            withContext(Dispatchers.Main) {
                assertTrue(engine.setLanguage(Locale.US) >= TextToSpeech.LANG_AVAILABLE)
                engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {}
                    override fun onDone(utteranceId: String?) { completed.complete(true) }
                    override fun onError(utteranceId: String?, errorCode: Int) { completed.complete(false) }
                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) { completed.complete(false) }
                })
                assertEquals(TextToSpeech.SUCCESS, engine.synthesizeToFile("Enve can read this paragraph aloud, then pause and resume at the same passage.", null, output, "verification"))
            }
            assertTrue(withTimeout(30_000) { completed.await() })
            val bytes = output.readBytes()
            assertTrue(bytes.size > 4_096)
            assertEquals("RIFF", String(bytes, 0, 4, Charsets.US_ASCII))
            val wave = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            var offset = 12
            var nonSilent = false
            while (offset + 8 <= bytes.size) {
                val size = wave.getInt(offset + 4)
                assertTrue(size >= 0 && size <= bytes.size - offset - 8)
                if (String(bytes, offset, 4, Charsets.US_ASCII) == "data") {
                    nonSilent = (offset + 8 until offset + 8 + size - 1 step 2)
                        .any { kotlin.math.abs(wave.getShort(it).toInt()) > 32 }
                    break
                }
                offset += 8 + size + size % 2
            }
            assertTrue("Synthesized PCM must contain audible speech samples", nonSilent)
        } finally {
            withContext(Dispatchers.Main) { engine.shutdown() }
            output.delete()
        }
    }
}
