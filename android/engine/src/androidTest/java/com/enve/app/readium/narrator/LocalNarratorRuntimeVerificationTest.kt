package com.enve.app.readium.narrator

import android.net.TrafficStats
import android.os.Process
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Locale
import kotlin.math.sqrt

@RunWith(AndroidJUnit4::class)
class LocalNarratorRuntimeVerificationTest {

    @Test
    fun enabledPacksNarrateLocallyWithEveryVoice(): Unit = runBlocking {
        val packs = InstrumentationRegistry.getArguments().getString("enveNarratorPacks").orEmpty()
            .split(',')
            .filter { it.isNotBlank() }
            .map { NarratorPack.valueOf(it.trim().uppercase(Locale.ROOT)) }
        assumeTrue("pass -e enveNarratorPacks KOKORO,SUPERTONIC,POCKET", packs.isNotEmpty())

        val runtime = LocalNarratorRuntime(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            for (pack in packs) {
                runtime.install(pack) {}
                assertTrue("${pack.title} is not installed", runtime.isInstalled(pack))
            }

            val uid = Process.myUid()
            val trafficBefore = TrafficStats.getUidRxBytes(uid) + TrafficStats.getUidTxBytes(uid)
            for (pack in packs) {
                for (voice in pack.voices) {
                    assertSpeech("${pack.title} $voice", pack, runtime.synthesize(pack, voice, SENTENCE, "en-US", 1f), 1.0..20.0)
                }
            }
            if (NarratorPack.SUPERTONIC in packs) {
                val audio = runtime.synthesize(NarratorPack.SUPERTONIC, "M1", GERMAN_SENTENCE, "de-DE", 1.2f)
                assertSpeech("Supertonic 3 German", NarratorPack.SUPERTONIC, audio, 1.0..20.0)
            }
            for (pack in packs) {
                val passage = runtime.synthesize(pack, pack.voices.first(), PASSAGE, "en", 1f)
                assertSpeech("${pack.title} passage", pack, passage, 30.0..300.0)
            }
            val traffic = TrafficStats.getUidRxBytes(uid) + TrafficStats.getUidTxBytes(uid) - trafficBefore
            assertTrue("synthesis used the network ($traffic bytes)", traffic < 16_384)
        } finally {
            runtime.close()
        }
    }

    private fun assertSpeech(label: String, pack: NarratorPack, audio: NarratorAudio, seconds: ClosedRange<Double>) {
        assertEquals(label, SAMPLE_RATES.getValue(pack), audio.sampleRate)
        assertTrue("$label has non-finite samples", audio.samples.all { it.isFinite() })
        val duration = audio.samples.size.toDouble() / audio.sampleRate
        assertTrue("$label lasted $duration s", duration in seconds)
        val rms = sqrt(audio.samples.sumOf { it.toDouble() * it } / audio.samples.size)
        assertTrue("$label is silent (RMS $rms)", rms > 0.005)
    }

    private companion object {
        val SAMPLE_RATES = mapOf(
            NarratorPack.KOKORO to 24_000,
            NarratorPack.SUPERTONIC to 44_100,
            NarratorPack.POCKET to 24_000,
            NarratorPack.PHONON to 24_000,
            NarratorPack.WOOF to 24_000,
        )
        const val SENTENCE = "Please close the window before you leave. The books beside the desk must stay dry."
        const val GERMAN_SENTENCE = "Bitte schließe das Fenster, bevor du gehst. Die Bücher neben dem Schreibtisch müssen trocken bleiben."
        val PASSAGE = List(2) {
            "The rain had stopped by the time she reached the old library. " +
                "She left her coat beside the door and walked between the quiet shelves. " +
                "At the far end of the room, a small lamp lit an open book. " +
                "Someone had marked a page with a folded map of the valley. " +
                "She studied the river, the bridge, and the narrow road beyond the hills. " +
                "For the first time that morning, she knew where she needed to go. " +
                "She closed the book carefully and carried the map back into the daylight."
        }.joinToString(" ")
    }
}
