package com.enve.app.storyalign.export

import com.enve.app.storyalign.align.AlignedChapter
import com.enve.app.storyalign.align.AlignedSentence
import com.enve.app.storyalign.align.AudioFile
import com.enve.app.storyalign.align.SentenceRange
import com.enve.app.storyalign.epub.EpubParser
import com.enve.app.storyalign.epub.EpubZip
import com.enve.app.storyalign.epub.parseXmlDocument
import org.jsoup.Jsoup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

class ReadAloudEpubBuilderTest {

    @Test fun outputQualityIsEmbeddedInTheSameArchiveAsItsNarration() {
        val original = EpubZip.from(ByteArrayInputStream(sampleEpub()))
        val document = EpubParser.parse(original)
        val item = document.spineOrderedManifest.first { it.href == "ch1.xhtml" }
        val audio = AudioFile(0, 0.0, 10.0, "storyalign/Audio/0000.m4a")
        val chapter = AlignedChapter(item, alignedSentences = listOf(
            AlignedSentence("The quick brown fox.", 0, SentenceRange(0, 0.0, 2.0, audio, emptyList())),
        ))
        val quality = StoryAlignOutputQuality(1, 2, 0.2)
        val output = ReadAloudEpubBuilder.build(original, document, listOf(chapter),
            listOf(ReadAloudEpubBuilder.AudioClipFile("0000.m4a", ByteArray(64))), "2026-10-20T00:00:00Z", quality)
        val entries = EpubZip.from(ByteArrayInputStream(output)).entries()
        assertTrue(entries.getValue(StoryAlignOutputQuality.ENTRY).contentEquals(quality.encode()))
        assertTrue(entries.keys.any { it.endsWith(".smil") })
    }


    @Test fun chaptersWithMatchingFileNamesKeepSeparateNarration() {
        val original = EpubZip.from(ByteArrayInputStream(sampleEpub()))
        val entries = original.entries().toMutableMap()
        val opf = parseXmlDocument(entries.getValue("OEBPS/content.opf"))
        opf.selectFirst("item")!!.attr("href", "part-one/chapter.xhtml")
        opf.selectFirst("manifest")!!.append("""<item id="c1_overlay" href="old.smil" media-type="application/smil+xml"/>""")
        entries["OEBPS/old.smil"] = "<smil/>".toByteArray()
        opf.selectFirst("manifest")!!.append("""<item id="c2" href="part-two/chapter.xhtml" media-type="application/xhtml+xml"/>""")
        opf.selectFirst("spine")!!.append("""<itemref idref="c2"/>""")
        entries["OEBPS/content.opf"] = opf.outerHtml().toByteArray()
        val chapterText = entries.remove("OEBPS/ch1.xhtml")!!
        entries["OEBPS/part-one/chapter.xhtml"] = chapterText
        entries["OEBPS/part-two/chapter.xhtml"] = chapterText
        val source = ByteArrayOutputStream().also { bytes ->
            ZipOutputStream(bytes).use { zip ->
                entries.forEach { (name, contents) ->
                    zip.putNextEntry(ZipEntry(name))
                    zip.write(contents)
                    zip.closeEntry()
                }
            }
        }.toByteArray()
        val zip = EpubZip.from(ByteArrayInputStream(source))
        val doc = EpubParser.parse(zip)
        val audio = AudioFile(0, 0.0, 100.0, "0000.m4a")
        val chapters = doc.spineOrderedManifest.mapIndexed { index, item ->
            AlignedChapter(item, alignedSentences = listOf(AlignedSentence(
                "The quick brown fox.", 0, SentenceRange(0, index * 10.0, index * 10.0 + 2, audio, emptyList()),
            )))
        }
        val output = ReadAloudEpubBuilder.build(zip, doc, chapters,
            listOf(ReadAloudEpubBuilder.AudioClipFile("0000.m4a", ByteArray(64))), "2026-10-12T00:00:00Z")
        val exported = EpubZip.from(ByteArrayInputStream(output)).entries()
        val manifest = parseXmlDocument(exported.getValue("OEBPS/content.opf")).select("item")
        assertEquals(2, manifest.count { it.attr("media-type") == "application/smil+xml" })
        val overlayPaths = chapters.map { chapter ->
            manifest.first { it.attr("id") == "${chapter.manifestItem.id}_overlay" }.attr("href")
        }
        assertEquals(2, overlayPaths.toSet().size)
        chapters.zip(overlayPaths).forEach { (chapter, path) ->
            val smil = exported.getValue("OEBPS/$path").toString(Charsets.UTF_8)
            assertTrue(smil.contains("${chapter.manifestItem.href}#${chapter.manifestItem.id}-sentence0"))
        }
    }

    @Test fun buildsValidNarratedEpub() {
        val srcBytes = sampleEpub()
        val doc = EpubParser.parse(EpubZip.from(ByteArrayInputStream(srcBytes)))
        val chapterItem = doc.spineOrderedManifest.first { it.href == "ch1.xhtml" }

        val audio = AudioFile(index = 0, startTime = 0.0, endTime = 100.0, path = "storyalign/Audio/0000.m4a")
        val s0 = AlignedSentence(
            xhtmlSentence = "The quick brown fox.",
            sentenceId = 0,
            sentenceRange = SentenceRange(0, 0.0, 2.0, audio, emptyList()),
        )
        val s1 = AlignedSentence(
            xhtmlSentence = "It jumped high.",
            sentenceId = 1,
            sentenceRange = SentenceRange(1, 2.0, 4.0, audio, emptyList()),
        )
        val chapter = AlignedChapter(chapterItem, alignedSentences = listOf(s0, s1))

        val out = ReadAloudEpubBuilder.build(
            original = EpubZip.from(ByteArrayInputStream(srcBytes)),
            doc = doc,
            alignedChapters = listOf(chapter),
            audioClips = listOf(ReadAloudEpubBuilder.AudioClipFile("0000.m4a", ByteArray(64) { 1 })),
            modifiedIso = "2026-07-05T00:00:00Z",
        )

        val outZip = EpubZip.from(ByteArrayInputStream(out))
        val entries = outZip.entries()

        assertNotNull(entries["OEBPS/storyalign/MediaOverlays/chapter-0.smil"])
        assertNotNull(entries["OEBPS/storyalign/Audio/0000.m4a"])

        val smil = entries["OEBPS/storyalign/MediaOverlays/chapter-0.smil"]!!.toString(Charsets.UTF_8)
        assertTrue(smil.contains("<par id=\"c1-sentence0\">"))
        assertTrue(smil.contains("clipBegin=\"0.000s\" clipEnd=\"2.000s\""))

        val opf = parseXmlDocument(entries["OEBPS/content.opf"]!!)
        val chapterOpfItem = opf.select("item").first { it.attr("id") == "c1" }
        assertEquals("c1_overlay", chapterOpfItem.attr("media-overlay"))
        assertTrue(opf.select("item").any { it.attr("id") == "c1_overlay" && it.attr("media-type") == "application/smil+xml" })
        assertTrue(opf.select("item").any { it.attr("href") == "storyalign/Audio/0000.m4a" })
        assertTrue(opf.select("meta").any { it.attr("property") == "media:duration" })

        val ch = entries["OEBPS/ch1.xhtml"]!!.toString(Charsets.UTF_8)
        assertTrue(ch.contains("id=\"c1-sentence0\""))
        assertTrue(ch.contains("id=\"c1-sentence1\""))

        val reparsed = EpubParser.parse(EpubZip.from(ByteArrayInputStream(out)))
        assertEquals("Test Book", reparsed.metaInfo.title)

        ZipInputStream(ByteArrayInputStream(out)).use { zis ->
            val first = zis.nextEntry!!
            assertEquals("mimetype", first.name)
            assertEquals(ZipEntry.STORED.toLong(), first.method.toLong())
        }
    }

    @Test fun ctcSparseSentenceIdsResolveToTheOriginalSentenceText() {
        val sentences = listOf("First sentence.", "Skipped sentence.", "Third sentence.", "Another skipped sentence.", "Fifth sentence.")
        val entries = ctcExport("<p>${sentences.joinToString(" ")}</p>", sentences, listOf(0, 2, 4))
        val chapter = Jsoup.parse(entries.getValue("OEBPS/ch1.xhtml").toString(Charsets.UTF_8))
        val smil = parseXmlDocument(entries.getValue("OEBPS/storyalign/MediaOverlays/chapter-0.smil"))
        assertEquals(listOf("c1-sentence0", "c1-sentence2", "c1-sentence4"), smil.select("text").map { it.attr("src").substringAfter('#') })
        for (id in listOf(0, 2, 4)) assertEquals(sentences[id], chapter.getElementById("c1-sentence$id")!!.text())
        assertEquals(5, chapter.select("span[id]").size)
    }

    @Test fun ctcRepeatedSentenceUsesItsLaterOriginalOccurrence() {
        val entries = ctcExport("<p>Yes. Between. Yes.</p>", listOf("Yes.", "Between.", "Yes."), listOf(2))
        val chapter = Jsoup.parse(entries.getValue("OEBPS/ch1.xhtml").toString(Charsets.UTF_8))
        assertEquals(listOf("c1-sentence0", "c1-sentence1", "c1-sentence2"), chapter.select("span[id]").map { it.id() })
        val smil = parseXmlDocument(entries.getValue("OEBPS/storyalign/MediaOverlays/chapter-0.smil"))
        assertEquals("c1-sentence2", smil.selectFirst("text")!!.attr("src").substringAfter('#'))
    }

    @Test fun ctcInlineTargetPreservesFormattingTextAndUniqueIds() {
        val body = "<p>Before. Hello <em id=\"emphasis\">brave <strong>world</strong> today. Next</em> sentence.</p>"
        val entries = ctcExport(body, listOf("Before.", "Hello brave world today.", "Next sentence."), listOf(1, 2))
        val chapter = Jsoup.parse(entries.getValue("OEBPS/ch1.xhtml").toString(Charsets.UTF_8))
        assertEquals("Hello brave world today.", chapter.getElementById("c1-sentence1")!!.text())
        assertEquals("Next sentence.", chapter.getElementById("c1-sentence2")!!.text())
        assertEquals("world", chapter.selectFirst("#c1-sentence1 em strong")!!.text())
        assertEquals(Jsoup.parse(body).body().wholeText(), chapter.body().wholeText())
        assertEquals(chapter.select("[id]").size, chapter.select("[id]").map { it.id() }.toSet().size)
    }

    @Test(expected = IllegalStateException::class)
    fun ctcRejectsAnAcceptedSentenceWithoutADomTarget() {
        ctcExport("<p>Actual sentence.</p>", listOf("Missing sentence."), listOf(0))
    }

    @Test(expected = IllegalStateException::class)
    fun ctcRejectsDuplicateDomTargets() {
        ctcExport("<p id=\"c1-sentence0\">Actual sentence.</p>", listOf("Actual sentence."), listOf(0))
    }

    private fun ctcExport(body: String, sentences: List<String>, accepted: List<Int>): Map<String, ByteArray> {
        val source = EpubZip.from(ByteArrayInputStream(sampleEpub("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>$body</body></html>")))
        val document = EpubParser.parse(source)
        val item = document.spineOrderedManifest.first().copy(xhtmlSentences = sentences)
        val audio = AudioFile(0, 0.0, 100.0, "storyalign/Audio/0000.m4a")
        val chapter = AlignedChapter(item, alignedSentences = accepted.map { id ->
            AlignedSentence(sentences[id], id, SentenceRange(id, id * 2.0, id * 2.0 + 1, audio, emptyList()))
        })
        val output = ReadAloudEpubBuilder.build(source, document, listOf(chapter),
            listOf(ReadAloudEpubBuilder.AudioClipFile("0000.m4a", ByteArray(64))), "2026-10-20T00:00:00Z",
            fullSourceTagging = true)
        return EpubZip.from(ByteArrayInputStream(output)).entries()
    }

    private fun sampleEpub(chapterXhtml: String? = null): ByteArray {
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
                    <dc:title>Test Book</dc:title>
                    <dc:language>en</dc:language>
                    <meta property="dcterms:modified">2020-01-01T00:00:00Z</meta>
                  </metadata>
                  <manifest>
                    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine><itemref idref="c1"/></spine>
                </package>
            """.trimIndent(),
            "OEBPS/ch1.xhtml" to (chapterXhtml ?: """
                <?xml version="1.0"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><body><p>The quick brown fox. It jumped high.</p></body></html>
            """.trimIndent()),
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
