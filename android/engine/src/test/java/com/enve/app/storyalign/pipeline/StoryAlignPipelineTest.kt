package com.enve.app.storyalign.pipeline

import com.enve.app.storyalign.align.AudioFile
import com.enve.app.storyalign.align.Transcription
import com.enve.app.storyalign.align.TranscriptionBuilder
import com.enve.app.storyalign.align.WordNormalizer
import com.enve.app.storyalign.align.WordTimeStamp
import com.enve.app.storyalign.epub.EpubParser
import com.enve.app.storyalign.epub.EpubZip
import com.enve.app.storyalign.epub.parseXmlDocument
import com.enve.app.storyalign.export.ReadAloudEpubBuilder
import com.enve.engine.storyalign.StoryAlignGranularity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class StoryAlignPipelineTest {

    private val audio = AudioFile(0, 0.0, 10_000.0, "storyalign/Audio/0000.m4a")

    @Test fun parseAlignExportProducesNarratedEpub() = runBlocking {
        val srcBytes = sampleEpub()
        val doc = EpubParser.parse(EpubZip.from(ByteArrayInputStream(srcBytes)))

        val transcriber = Transcriber { syntheticTranscription(doc) }

        val result = StoryAlignPipeline().run(
            epub = EpubZip.from(ByteArrayInputStream(srcBytes)),
            granularity = StoryAlignGranularity.SENTENCE,
            transcriber = transcriber,
            audioClips = listOf(ReadAloudEpubBuilder.AudioClipFile("0000.m4a", ByteArray(128) { 7 })),
            modifiedIso = "2026-07-05T00:00:00Z",
        )

        assertTrue("score=${result.report.score}", result.report.score >= 0.8)
        assertTrue(result.report.alignedSentences > 0)

        val outZip = EpubZip.from(ByteArrayInputStream(result.readAloudEpub))
        val reparsed = EpubParser.parse(EpubZip.from(ByteArrayInputStream(result.readAloudEpub)))
        assertEquals("Pipeline Book", reparsed.metaInfo.title)

        assertNotNull(outZip.entries()["OEBPS/storyalign/MediaOverlays/ch1.smil"])
        val opf = parseXmlDocument(outZip.entries()["OEBPS/content.opf"]!!)
        assertTrue(opf.select("item").any { it.attr("media-overlay").isNotEmpty() })
        assertTrue(opf.select("item").any { it.attr("media-type") == "application/smil+xml" })

        val ch1 = outZip.entries()["OEBPS/ch1.xhtml"]!!.toString(Charsets.UTF_8)
        assertTrue(ch1.contains("-sentence"))
    }

    private fun syntheticTranscription(doc: com.enve.app.storyalign.epub.EpubDocument): Transcription {
        val normalizer = WordNormalizer()
        val words = ArrayList<WordTimeStamp>()
        var i = 0
        for (chapter in doc.spineOrderedManifest) {
            for (sentence in chapter.xhtmlSentences) {
                val normalized = normalizer.normalizeWordsInSentence(sentence)
                for (w in normalized.split(Regex("\\s+")).filter { it.isNotBlank() }) {
                    val token = w.filterNot { it.isWhitespace() }.lowercase()
                    if (token.isEmpty()) continue
                    words.add(WordTimeStamp(token, i * 0.5, i * 0.5 + 0.4, audio, i, -1, -1))
                    i++
                }
            }
        }
        return TranscriptionBuilder.fromWords(words)
    }

    private fun sampleEpub(): ByteArray {
        val entries = linkedMapOf(
            "mimetype" to "application/epub+zip",
            "META-INF/container.xml" to """
                <?xml version="1.0"?>
                <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
                  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
            """.trimIndent(),
            "OEBPS/content.opf" to """
                <?xml version="1.0"?>
                <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0" unique-identifier="id">
                  <metadata>
                    <dc:identifier id="id">urn:uuid:test</dc:identifier>
                    <dc:title>Pipeline Book</dc:title>
                    <dc:language>en</dc:language>
                  </metadata>
                  <manifest>
                    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
                </package>
            """.trimIndent(),
            "OEBPS/ch1.xhtml" to """
                <?xml version="1.0"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><body>
                  <p>The quick brown fox jumped over the lazy dog. She sells sea shells by the shore.</p>
                </body></html>
            """.trimIndent(),
            "OEBPS/ch2.xhtml" to """
                <?xml version="1.0"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><body>
                  <p>It was the best of times it was the worst of times.</p>
                  <p>Call me Ishmael and let us begin the journey now.</p>
                </body></html>
            """.trimIndent(),
        )
        val bos = ByteArrayOutputStream()
        ZipOutputStream(bos).use { zos ->
            for ((name, content) in entries) {
                zos.putNextEntry(ZipEntry(name))
                zos.write(content.toByteArray(Charsets.UTF_8))
                zos.closeEntry()
            }
        }
        return bos.toByteArray()
    }
}
