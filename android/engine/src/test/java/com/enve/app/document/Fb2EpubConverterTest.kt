package com.enve.app.document

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.util.zip.ZipFile

class Fb2EpubConverterTest {
    @Test
    fun convertsMetadataChaptersFormattingAndImages() {
        val directory = Files.createTempDirectory("fb2-converter-test").toFile()
        try {
            val source = directory.resolve("source.fb2").apply { writeText(sampleFb2) }
            val destination = directory.resolve("converted.epub")

            Fb2EpubConverter().convertToEpub(source, destination)

            assertTrue(destination.isFile)
            ZipFile(destination).use { epub ->
                assertEquals(
                    "application/epub+zip",
                    epub.getInputStream(epub.getEntry("mimetype")).readBytes().toString(StandardCharsets.US_ASCII),
                )
                val packageDocument = epub.readText("OEBPS/content.opf")
                assertTrue(packageDocument.contains("<dc:title>Fixture &amp; Test</dc:title>"))
                assertTrue(packageDocument.contains("<dc:creator>Ada Lovelace</dc:creator>"))
                assertTrue(packageDocument.contains("properties=\"cover-image\""))

                val chapter = epub.readText("OEBPS/chapter_0000.xhtml")
                assertTrue(chapter.contains("<h1>Opening</h1>"))
                assertTrue(chapter.contains("A <em>formatted</em> paragraph."))
                assertTrue(chapter.contains("resources/cover.png"))
                assertTrue(epub.getEntry("OEBPS/resources/cover.png") != null)
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun rejectsFilesThatAreNotFb2() {
        val directory = Files.createTempDirectory("fb2-converter-invalid-test").toFile()
        try {
            val source = directory.resolve("source.fb2").apply { writeText("<book><p>Not FB2</p></book>") }
            try {
                Fb2EpubConverter().convertToEpub(source, directory.resolve("converted.epub"))
                fail("Expected EbookNormalizationException")
            } catch (error: EbookNormalizationException) {
                assertTrue(error.message.orEmpty().contains("valid FB2"))
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun ZipFile.readText(path: String): String =
        getInputStream(getEntry(path)).readBytes().toString(StandardCharsets.UTF_8)

    private companion object {
        const val sampleFb2 = """
            <?xml version="1.0" encoding="utf-8"?>
            <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
              <description>
                <title-info>
                  <book-title>Fixture &amp; Test</book-title>
                  <author><first-name>Ada</first-name><last-name>Lovelace</last-name></author>
                  <lang>en</lang>
                  <coverpage><image l:href="#cover"/></coverpage>
                </title-info>
              </description>
              <body>
                <section>
                  <title><p>Opening</p></title>
                  <p>A <emphasis>formatted</emphasis> paragraph.</p>
                  <image l:href="#cover"/>
                </section>
              </body>
              <binary id="cover" content-type="image/png">iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=</binary>
            </FictionBook>
        """
    }
}
