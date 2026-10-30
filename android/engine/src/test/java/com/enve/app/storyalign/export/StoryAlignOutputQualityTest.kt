package com.enve.app.storyalign.export

import com.enve.app.storyalign.StoryAlignOutputStore
import com.enve.app.storyalign.StoryAlignReport
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class StoryAlignOutputQualityTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun promotedOutputCarriesItsOwnQualityEvenIfTheDatabaseReportIsStale() {
        val outputs = StoryAlignOutputStore(temporary.newFolder())
        val accepted = outputs.acceptedFile("job")
        epub(accepted, mapOf(StoryAlignOutputQuality.ENTRY to StoryAlignOutputQuality(3, 10, 0.3).encode()))
        val staleReport = StoryAlignReport(3, 10)
        val candidate = outputs.prepareCandidate("job")
        epub(candidate, mapOf(StoryAlignOutputQuality.ENTRY to StoryAlignOutputQuality(9, 10, 0.9).encode()))
        outputs.promoteCandidate("job")
        assertEquals(3, staleReport.alignedSentences)
        assertEquals(9, StoryAlignOutputQuality.read(accepted)!!.metadata!!.acceptedSentenceCount)
        assertEquals(3, StoryAlignOutputQuality.read(outputs.previousFile("job"))!!.metadata!!.acceptedSentenceCount)
    }

    @Test
    fun legacyOutputCountsActualNarrationClips() {
        val file = temporary.newFile("legacy.epub")
        epub(file, mapOf("overlay.smil" to "<smil><par><audio/></par><par><audio/></par></smil>".toByteArray()))
        val snapshot = StoryAlignOutputQuality.read(file)!!
        assertNull(snapshot.metadata)
        assertEquals(2, snapshot.clipCount)
    }

    @Test
    fun malformedQualityDoesNotFallBackToAnUnverifiedReport() {
        val file = temporary.newFile("broken.epub")
        epub(file, mapOf(StoryAlignOutputQuality.ENTRY to "{\"acceptedSentenceCount\":9,\"eligibleSentenceCount\":1,\"audioCoverage\":0.8}".toByteArray()))
        assertNull(StoryAlignOutputQuality.read(file))
    }

    @Test
    fun oversizedMetadataIsRejectedBeforeDecompression() {
        val file = temporary.newFile("oversized.epub")
        epub(file, mapOf(StoryAlignOutputQuality.ENTRY to ByteArray(65_537) { 32 }))
        assertNull(StoryAlignOutputQuality.read(file))
    }

    @Test
    fun unrecognizedLegacyOutputFailsClosed() {
        val file = temporary.newFile("empty.epub")
        epub(file, emptyMap())
        assertNull(StoryAlignOutputQuality.read(file))
    }

    private fun epub(file: File, entries: Map<String, ByteArray>) {
        ZipOutputStream(file.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("mimetype"))
            zip.write("application/epub+zip".toByteArray())
            zip.closeEntry()
            entries.forEach { (name, bytes) ->
                zip.putNextEntry(ZipEntry(name))
                zip.write(bytes)
                zip.closeEntry()
            }
        }
    }
}
