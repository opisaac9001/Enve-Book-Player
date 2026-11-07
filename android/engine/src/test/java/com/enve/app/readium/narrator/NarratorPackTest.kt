package com.enve.app.readium.narrator

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Locale

class NarratorPackTest {

    @Test
    fun downloadSizesMatchPinnedUpstreamAssets() {
        assertEquals(132_353_410L + 3_438_244L + 5_724_857L, NarratorPack.KOKORO.downloadBytes)
        assertEquals(
            setOf("misaki-en_us-g2p.json", "misaki-en_us-g2p.onnx"),
            NarratorPack.KOKORO.assets.downloads.map { it.name }.toSet(),
        )
        assertEquals(128_774_318L, NarratorPack.SUPERTONIC.downloadBytes)
        assertEquals(98_336_520L + 958_542L, NarratorPack.POCKET.downloadBytes)
    }

    @Test
    fun longKokoroInputPreservesTheWholePassage() {
        val sentence = "ʃi ˈOpᵊnd ðə bˈʊk."
        val passage = List(80) { sentence }.joinToString(" ").codePoints().toArray()
        val groups = kokoroSentences(passage)
        assertTrue(groups.size > 1 && groups.all { it.size <= 500 })
        assertEquals(passage.toList(), groups.flatMap { it.toList() })
    }

    @Test
    fun punctuationOnlyKokoroInputHasNoSpeech() {
        assertEquals(0, kokoroSentences("… — “” ! ?".codePoints().toArray()).size)
        assertEquals(0, kokoroSentences(IntArray(0)).size)
        assertEquals(1, kokoroSentences("… ʃi.".codePoints().toArray()).size)
    }

    @Test
    fun voicesMapToUpstreamSpeakerIds() {
        assertEquals(listOf("af_heart", "af_bella", "am_michael", "am_puck"), NarratorPack.KOKORO.voices)
        assertEquals(listOf(3, 2, 16, 18), NarratorPack.KOKORO.speakerIds)
        assertEquals(listOf("F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"), NarratorPack.SUPERTONIC.voices)
        assertEquals((0..9).toList(), NarratorPack.SUPERTONIC.speakerIds)
        assertEquals(listOf("alba"), NarratorPack.POCKET.voices)
        NarratorPack.entries.forEach { assertEquals(it.voices.size, it.speakerIds.size) }
    }

    @Test
    fun languageTagsResolveToSupportedBaseCodes() {
        assertEquals("en", NarratorPack.KOKORO.languageCode("en-US"))
        assertEquals("en", NarratorPack.POCKET.languageCode("en_GB"))
        assertEquals("de", NarratorPack.SUPERTONIC.languageCode("de-DE"))
        assertEquals("pt", NarratorPack.SUPERTONIC.languageCode(" PT-br "))
        assertEquals(31, NarratorPack.SUPERTONIC.languages.size)
        assertThrows(IllegalArgumentException::class.java) { NarratorPack.KOKORO.languageCode("fr") }
        assertThrows(IllegalArgumentException::class.java) { NarratorPack.POCKET.languageCode("de") }
        assertThrows(IllegalArgumentException::class.java) { NarratorPack.SUPERTONIC.languageCode("na") }
    }

    @Test
    fun epubLanguageCodesResolveToSupportedChoices() {
        assertEquals("en", NarratorPack.KOKORO.languageCode("eng"))
        assertEquals("en", NarratorPack.POCKET.languageCode("ENG"))
        assertEquals("de", NarratorPack.SUPERTONIC.languageCode("deu"))
        assertEquals("id", NarratorPack.SUPERTONIC.languageCode("ind"))
        assertThrows(IllegalArgumentException::class.java) { NarratorPack.KOKORO.languageCode("fra") }
        val device = Locale.getDefault()
        try {
            Locale.setDefault(Locale.GERMANY)
            assertEquals("de", NarratorPack.SUPERTONIC.languageCode("und"))
            assertEquals("en", NarratorPack.KOKORO.languageCode("mul"))
            Locale.setDefault(Locale.forLanguageTag("sw-KE"))
            assertEquals("en", NarratorPack.SUPERTONIC.languageCode("MUL"))
        } finally {
            Locale.setDefault(device)
        }
    }

    @Test
    fun modelConfigReferencesOnlyPinnedFiles() {
        val directory = File("narrator")
        NarratorPack.entries.forEach { pack ->
            val model = pack.modelConfig(directory, threads = 2)
            val paths = listOf(
                model.kokoro.model, model.kokoro.voices, model.kokoro.tokens, model.kokoro.lexicon,
                model.supertonic.durationPredictor, model.supertonic.textEncoder, model.supertonic.vectorEstimator,
                model.supertonic.vocoder, model.supertonic.ttsJson, model.supertonic.unicodeIndexer, model.supertonic.voiceStyle,
                model.pocket.lmFlow, model.pocket.lmMain, model.pocket.encoder, model.pocket.decoder,
                model.pocket.textConditioner, model.pocket.vocabJson, model.pocket.tokenScoresJson,
            ).filter { it.isNotEmpty() }
            val pinned = pack.assets.files.map { File(directory, it.name).absolutePath }.toSet()
            assertTrue(pack.name, paths.isNotEmpty() && pinned.containsAll(paths))
            assertEquals(2, model.numThreads)
        }
        assertTrue(NarratorPack.POCKET.assets.downloads.any { it.name == POCKET_VOICE })
    }

    @Test
    fun pinnedAssetsAreWellFormed() {
        val digest = Regex("[0-9a-f]{64}")
        val fileName = Regex("[A-Za-z0-9_.-]+")
        NarratorPack.entries.forEach { pack ->
            val assets = pack.assets
            assertTrue(pack.name, assets.archive.sha256.matches(digest) && assets.archive.url.startsWith("https://"))
            assertTrue(pack.name, assets.files.all { it.sha256.matches(digest) && it.name.matches(fileName) && it.bytes > 0 })
            assertEquals(pack.name, assets.files.size, assets.files.map { it.name }.toSet().size)
            assertTrue(pack.name, assets.downloads.all { it.url!!.startsWith("https://") })
        }
    }
}
