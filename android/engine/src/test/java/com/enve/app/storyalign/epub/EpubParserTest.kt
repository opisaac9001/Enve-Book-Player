package com.enve.app.storyalign.epub

import com.enve.engine.storyalign.StoryAlignGranularity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class EpubParserTest {

    private fun fixture(name: String): EpubZip {
        val stream = javaClass.getResourceAsStream("/storyalign/$name")
            ?: error("missing fixture $name")
        return stream.use { EpubZip.from(it) }
    }

    @Test
    fun romeoAndJuliet_structural() {
        val zip = fixture("Romeo_and_Juliet.epub")
        val opfPath = parseEpubContainer(zip.bytes("META-INF/container.xml")!!)
        assertEquals("OEBPS/content.opf", opfPath)

        val opf = parseXmlDocument(zip.bytes(opfPath)!!)
        val meta = parseEpubMetaInfo(opf)
        assertEquals("Romeo and Juliet", meta.title)
        assertEquals("William Shakespeare", meta.creator)
        assertEquals("en", meta.language)
        assertEquals("2.0", meta.version)
        assertTrue(meta.isEpub2)

        val spine = parseEpubSpine(opf)
        assertEquals("ncx", spine.toc)
        assertEquals(10, spine.items.size)

        val manifest = parseEpubManifest(opf)
        assertNotNull(manifest.firstOrNull { it.mediaType == EpubMediaTypes.NCX_XML })

        val guide = parseEpubGuide(opf)
        assertTrue(guide.any { it.type == "toc" })
        assertTrue(guide.any { it.type == "cover" })
    }

    @Test
    fun romeoAndJuliet_ncxAndChapterEntries() {
        val zip = fixture("Romeo_and_Juliet.epub")
        val opf = parseXmlDocument(zip.bytes("OEBPS/content.opf")!!)
        val ncxItem = EpubOpfResolver.ncxManifestItem(parseEpubManifest(opf), parseEpubSpine(opf))!!
        val ncx = parseEpubNcx(zip.bytes("OEBPS/${ncxItem.href}")!!, ncxItem.href, ncxItem.id)
        assertEquals("Romeo and Juliet", ncx.docTitle)
        assertTrue(ncx.navPoints.isNotEmpty())

        val chapters = EpubParser.chapterEntries(zip)
        assertEquals(10, chapters.size)

        assertTrue(chapters.any { it.navLabel.contains("TRAGEDY OF ROMEO AND JULIET") })
    }

    @Test
    fun searchTheSky_isEpub3WithNav() {
        val zip = fixture("Search_the_Sky.epub")
        val opfPath = parseEpubContainer(zip.bytes("META-INF/container.xml")!!)
        assertEquals("epub/content.opf", opfPath)
        val meta = parseEpubMetaInfo(parseXmlDocument(zip.bytes(opfPath)!!))
        assertEquals("3.0", meta.version)
        assertTrue(!meta.isEpub2)
        assertTrue(EpubParser.chapterEntries(zip).isNotEmpty())
    }

    @Test(expected = StoryAlignParseException::class)
    fun missingContainer_throws() {
        val empty = EpubZip.from(ByteArrayInputStream(buildZip(emptyMap())))
        EpubParser.parse(empty)
    }

    @Test
    fun fullParse_producesTextAndSentences() {
        val doc = EpubParser.parse(EpubZip.from(ByteArrayInputStream(sampleEpub())))

        assertEquals("Test Book", doc.metaInfo.title)
        assertTrue(!doc.isEpub2)

        val chapters = doc.spineOrderedManifest
        assertEquals(2, chapters.size)
        assertEquals("ch1.xhtml", chapters[0].href)
        assertEquals("ch2.xhtml", chapters[1].href)

        assertEquals("Chapter One", chapters[0].name)

        assertTrue(chapters[0].text!!.contains("The quick brown fox"))
        assertTrue(chapters[0].xhtmlSentences.size >= 2)
        assertTrue(chapters[0].xhtmlSentences.first().contains("quick brown fox"))

        assertTrue(chapters[0].xhtmlSentences.none { it.contains("BLOCK_BOUNDARY") })

        assertTrue(chapters[1].xhtmlSentences.size >= 2)

        val entries = EpubParser.chapterEntries(EpubZip.from(ByteArrayInputStream(sampleEpub())))
        assertEquals(2, entries.size)
        assertEquals("Chapter One", entries[0].navLabel)
    }

    @Test
    fun alreadyAligned_throws() {
        val opf = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
              <metadata>
                <dc:title>X</dc:title>
                <meta property="storyteller:media-overlays-modified">2026</meta>
              </metadata>
            </package>
        """.trimIndent()
        try {
            parseEpubMetaInfo(parseXmlDocument(opf.toByteArray()))
            error("expected StoryAlignParseException")
        } catch (e: StoryAlignParseException) {
            assertTrue(e.message!!.contains("already been aligned"))
        }
    }

    private fun buildZip(entries: Map<String, String>): ByteArray {
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

    private fun sampleEpub(): ByteArray = buildZip(
        linkedMapOf(
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
                    <dc:creator>Tester</dc:creator>
                    <dc:language>en</dc:language>
                  </metadata>
                  <manifest>
                    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine>
                    <itemref idref="c1"/>
                    <itemref idref="c2"/>
                  </spine>
                </package>
            """.trimIndent(),
            "OEBPS/nav.xhtml" to """
                <?xml version="1.0"?>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
                  <body>
                    <nav epub:type="toc">
                      <ol>
                        <li><a href="ch1.xhtml">Chapter One</a></li>
                        <li><a href="ch2.xhtml">Chapter Two</a></li>
                      </ol>
                    </nav>
                  </body>
                </html>
            """.trimIndent(),
            "OEBPS/ch1.xhtml" to """
                <?xml version="1.0"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><body>
                  <p>The quick brown fox. It jumped over the lazy dog.</p>
                </body></html>
            """.trimIndent(),
            "OEBPS/ch2.xhtml" to """
                <?xml version="1.0"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><body>
                  <p>Hello world.</p>
                  <p>Goodbye now.</p>
                </body></html>
            """.trimIndent(),
        ),
    )

    @Test
    fun granularityCollapsesToSentenceForWordModes() {

        assertEquals(StoryAlignGranularity.SENTENCE.useWordTokenizer, false)
        assertEquals(StoryAlignGranularity.WORD.useWordTokenizer, true)
        val doc = EpubParser.parse(EpubZip.from(ByteArrayInputStream(sampleEpub())), StoryAlignGranularity.WORD)
        assertTrue(doc.spineOrderedManifest[0].xhtmlSentences.isNotEmpty())
    }
}
