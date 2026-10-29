package com.enve.app.ui.screens.reader

import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ReaderIllustrationLoaderTest {
    @Test
    fun smallPicturesDecodeAtTheirOwnSize() {
        assertEquals(1, ReaderIllustrationLoader.sampleSizeFor(1200, 1600))
        assertEquals(1, ReaderIllustrationLoader.sampleSizeFor(0, 0))
    }

    @Test
    fun hugeScansAreSampledDownToTheBudget() {
        assertEquals(2, ReaderIllustrationLoader.sampleSizeFor(4000, 3000))
        assertEquals(8, ReaderIllustrationLoader.sampleSizeFor(16_000, 12_000))
        assertEquals(4, ReaderIllustrationLoader.sampleSizeFor(4000, 3000, maxPixels = 1_000_000L))
    }

    @Test
    fun containerPathsAreZipEntryNames() {
        assertEquals("OEBPS/images/map#one.jpg", ReaderIllustrationLoader.containerPath("/OEBPS/images/map#one.jpg"))
        assertEquals("images/plate 2.png", ReaderIllustrationLoader.containerPath(" images/plate 2.png "))
        assertNull(ReaderIllustrationLoader.containerPath("   "))
        assertNull(ReaderIllustrationLoader.containerPath("../outside.png"))
    }

    @Test
    fun zipEntriesAreReadByTheirContainerPath() {
        val archive = File.createTempFile("illustration", ".epub")
        try {
            ZipOutputStream(archive.outputStream()).use { zip ->
                zip.putNextEntry(ZipEntry("OEBPS/images/map.jpg"))
                zip.write(byteArrayOf(1, 2, 3))
                zip.closeEntry()
            }
            assertArrayEquals(byteArrayOf(1, 2, 3), ReaderIllustrationLoader.readZipEntry(archive, "OEBPS/images/map.jpg"))
            assertNull(ReaderIllustrationLoader.readZipEntry(archive, "OEBPS/images/missing.jpg"))
        } finally {
            archive.delete()
        }
    }

    @Test
    fun aFileThatIsNotAnArchiveYieldsNothing() {
        val file = File.createTempFile("illustration", ".azw3")
        try {
            file.writeText("not a zip")
            assertNull(ReaderIllustrationLoader.readZipEntry(file, "anything"))
        } finally {
            file.delete()
        }
    }
}
