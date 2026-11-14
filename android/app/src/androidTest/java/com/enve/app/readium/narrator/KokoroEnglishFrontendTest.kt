package com.enve.app.readium.narrator

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KokoroEnglishFrontendTest {

    private var frontend: KokoroEnglishFrontend? = null

    @Before
    fun openFrontend() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = context.noBackupFilesDir.resolve("narrator").listFiles().orEmpty().firstOrNull { candidate ->
            candidate.isDirectory && candidate.name.startsWith("kokoro-") &&
                candidate.resolve("misaki-en_us-g2p.onnx").isFile && candidate.resolve("misaki-en_us-g2p.json").isFile
        }
        assumeTrue("misaki-en_us-g2p pack not installed on device", directory != null)
        frontend = KokoroEnglishFrontend(directory!!)
    }

    @After
    fun closeFrontend() {
        frontend?.close()
    }

    private fun spoken(text: String): String {
        val codepoints = frontend!!.phonemes(text)
        return String(codepoints, 0, codepoints.size)
    }

    @Test
    fun lexiconSentenceKeepsEveryWord() {
        assertEquals("ʃˌi ˈOpᵊnd ðə bˈʊk.", spoken("She opened the book."))
    }

    @Test
    fun outOfVocabularyNameIsDecodedNotDropped() {
        val name = spoken("Vexalorn")
        assertTrue(name.isNotEmpty())
        assertFalse(name.contains(' '))
        assertEquals(3, spoken("She saw Vexalorn.").trimEnd('.').split(' ').size)
    }

    @Test
    fun numbersAreSpelledOutNotDropped() {
        assertArrayEquals(
            frontend!!.phonemes("She paid twelve dollars and fifty cents for three books."),
            frontend!!.phonemes("She paid $12.50 for 3 books."),
        )
        assertArrayEquals(
            frontend!!.phonemes("Chapter twenty one, page three hundred two."),
            frontend!!.phonemes("Chapter 21, page 302."),
        )
        assertArrayEquals(
            frontend!!.phonemes("Her second try was fifty percent better."),
            frontend!!.phonemes("Her 2nd try was 50% better."),
        )
    }

    @Test
    fun punctuationAndContractionsSurvive() {
        val line = spoken("Wait — really?! “Yes,” she said… Don't stop.")
        for (mark in "—?!“”,.") {
            assertTrue("missing $mark", line.contains(mark))
        }
        assertTrue(line.contains("..."))
        assertArrayEquals(frontend!!.phonemes("Wait…"), frontend!!.phonemes("Wait..."))
        assertTrue(line.contains("dˈOnt"))
        assertFalse(line.any { it.isDigit() })
    }
}
