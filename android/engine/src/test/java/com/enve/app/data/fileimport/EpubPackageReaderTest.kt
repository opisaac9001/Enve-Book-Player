package com.enve.app.data.fileimport

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class EpubPackageReaderTest {
    @get:Rule val folder = TemporaryFolder()

    private val container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
    """.trimIndent()

    private fun epub(opf: String, extra: Map<String, ByteArray> = emptyMap()): File {
        val file = folder.newFile("book-${System.nanoTime()}.epub")
        ZipOutputStream(file.outputStream()).use { zip ->
            fun put(name: String, bytes: ByteArray) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(bytes)
                zip.closeEntry()
            }
            put("mimetype", "application/epub+zip".toByteArray())
            put("META-INF/container.xml", container.toByteArray())
            put("OEBPS/content.opf", opf.toByteArray())
            extra.forEach { (name, bytes) -> put(name, bytes) }
        }
        return file
    }

    private fun opf(metadata: String, manifest: String) = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
          <metadata>$metadata</metadata>
          <manifest>$manifest</manifest>
        </package>
    """.trimIndent()

    @Test
    fun readsTitleCreatorsCoverAndReadAloud() {
        val coverBytes = byteArrayOf(1, 2, 3, 4)
        val book = epub(
            opf(
                metadata = """
                    <dc:title>  The   Web Serial </dc:title>
                    <dc:title>Ignored Subtitle</dc:title>
                    <dc:creator>Ada</dc:creator>
                    <dc:creator>Grace</dc:creator>
                """,
                manifest = """
                    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml" media-overlay="o1"/>
                    <item id="o1" href="ch1.smil" media-type="application/smil+xml"/>
                    <item id="img" href="images/front%20cover.jpg" media-type="image/jpeg" properties="cover-image"/>
                """,
            ),
            mapOf("OEBPS/images/front cover.jpg" to coverBytes),
        )
        val cover = File(folder.root, "cover.img")

        val metadata = requireNotNull(EpubPackageReader.read(book, cover))

        assertEquals("The Web Serial", metadata.title)
        assertEquals("Ada, Grace", metadata.author)
        assertTrue(metadata.readAlongAvailable)
        assertTrue(metadata.coverWritten)
        assertArrayEquals(coverBytes, cover.readBytes())
    }

    @Test
    fun fallsBackToLegacyCoverMeta() {
        val book = epub(
            opf(
                metadata = """<dc:title>Legacy</dc:title><meta name="cover" content="art"/>""",
                manifest = """<item id="art" href="art.png" media-type="image/png"/>""",
            ),
            mapOf("OEBPS/art.png" to byteArrayOf(9)),
        )
        val cover = File(folder.root, "legacy.img")

        val metadata = requireNotNull(EpubPackageReader.read(book, cover))

        assertTrue(metadata.coverWritten)
        assertFalse(metadata.readAlongAvailable)
        assertNull(metadata.author)
    }

    @Test
    fun ignoresCoversOutsideThePackage() {
        val book = epub(
            opf(
                metadata = "<dc:title>Escape</dc:title>",
                manifest = """<item id="cover" href="../../outside.jpg" media-type="image/jpeg" properties="cover-image"/>""",
            ),
            mapOf("outside.jpg" to byteArrayOf(7)),
        )
        val cover = File(folder.root, "escape.img")

        val metadata = requireNotNull(EpubPackageReader.read(book, cover))

        assertFalse(metadata.coverWritten)
        assertFalse(cover.exists())
    }

    private fun withDoctype(doctype: String, title: String) = """
        <?xml version="1.0"?>
        $doctype
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata><dc:title>$title</dc:title></metadata>
          <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
        </package>
    """.trimIndent()

    @Test
    fun rejectsExternalEntities() {
        val secret = folder.newFile("secret.txt").apply { writeText("private") }
        val book = epub(withDoctype("""<!DOCTYPE package [<!ENTITY leak SYSTEM "${secret.toURI()}">]>""", "&leak;"))

        assertNull(EpubPackageReader.read(book, File(folder.root, "entity.img")))
    }

    @Test
    fun rejectsInternalEntityExpansion() {
        val entities = buildString {
            append("<!ENTITY a0 \"lol\">")
            (1..9).forEach { level -> append("<!ENTITY a$level \"${"&a${level - 1};".repeat(10)}\">") }
        }
        val book = epub(withDoctype("<!DOCTYPE package [$entities]>", "&a9;"))

        assertNull(EpubPackageReader.read(book, File(folder.root, "laughs.img")))
    }

    @Test
    fun rejectsAnyDocumentTypeDeclaration() {
        val book = epub(withDoctype("""<!DOCTYPE package PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://127.0.0.1:9/dtd">""", "Plain"))

        assertNull(EpubPackageReader.read(book, File(folder.root, "doctype.img")))
    }

    @Test
    fun rejectsDocumentTypeInTheContainer() {
        val file = folder.newFile("container-doctype.epub")
        ZipOutputStream(file.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("META-INF/container.xml"))
            zip.write("""<?xml version="1.0"?><!DOCTYPE container [<!ENTITY p "content.opf">]><container><rootfiles><rootfile full-path="&p;"/></rootfiles></container>""".toByteArray())
            zip.closeEntry()
        }

        assertNull(EpubPackageReader.read(file, File(folder.root, "container.img")))
    }

    @Test
    fun returnsNullForArchivesWithoutAPackage() {
        val file = folder.newFile("broken.epub")
        ZipOutputStream(file.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("mimetype"))
            zip.write("application/epub+zip".toByteArray())
            zip.closeEntry()
        }

        assertNull(EpubPackageReader.read(file, File(folder.root, "broken.img")))
    }

    @Test
    fun returnsNullForFilesThatAreNotArchives() {
        val file = folder.newFile("plain.epub").apply { writeText("not a zip") }

        assertNull(EpubPackageReader.read(file, File(folder.root, "plain.img")))
    }

    @Test
    fun resolvesRelativePathsWithinThePackage() {
        assertEquals("OEBPS/images/a b.jpg", EpubPackageReader.resolve("OEBPS", "images/a%20b.jpg#frag"))
        assertEquals("images/a.jpg", EpubPackageReader.resolve("OEBPS", "../images/a.jpg"))
        assertNull(EpubPackageReader.resolve("OEBPS", "../../a.jpg"))
        assertNull(EpubPackageReader.resolve("OEBPS", "https://example.com/a.jpg"))
        assertNull(EpubPackageReader.resolve("", "/etc/passwd"))
    }
}
