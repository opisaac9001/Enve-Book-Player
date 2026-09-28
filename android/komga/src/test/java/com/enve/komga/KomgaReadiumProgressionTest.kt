package com.enve.komga

import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import com.enve.komga.dto.KomgaMediaDto
import com.enve.komga.dto.KomgaR2Positions
import com.enve.komga.dto.KomgaR2Progression
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class KomgaReadiumProgressionTest {

    private val wire = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
    }

    private val readiumLocator = """
        {"href":"EPUB/chapter-010.xhtml","type":"application/xhtml+xml","title":"Chapter 10",
         "locations":{"fragments":["p3","t=12","epubcfi(/4/2)"],"progression":0.7,"position":20,
         "totalProgression":0.195,"cssSelector":"#p3"},
         "text":{"before":"abc ","highlight":"Hello world","after":" def"}}
    """.trimIndent()

    @Test
    fun encodesReaderLocatorAsKomgaProgression() {
        val locator = KomgaReadiumProgression.locatorFrom(readiumLocator, 0.195f)!!
        val payload = KomgaReadiumProgression.encode(locator, Instant.parse("2026-09-26T11:22:10.500Z").toEpochMilli())

        assertEquals(
            wire.parseToJsonElement(
                """
                {"modified":"2026-09-26T11:22:10.500Z",
                 "device":{"id":"enve-android","name":"Enve"},
                 "locator":{"href":"EPUB/chapter-010.xhtml","type":"application/xhtml+xml","title":"Chapter 10",
                  "locations":{"fragment":["p3"],"progression":0.7,"position":20,"totalProgression":0.19499999284744263},
                  "text":{"before":"abc ","highlight":"Hello world","after":" def"}}}
                """.trimIndent(),
            ),
            wire.parseToJsonElement(payload),
        )
    }

    @Test
    fun readsBridgeCheckpointThroughItsReadiumLocator() {
        val checkpoint = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            observedAt = 1L,
            sourceEngine = ReaderEngineKind.READIUM,
            href = "EPUB/chapter-010.xhtml",
            totalProgression = 0.195,
            nativeReadiumLocatorJson = readiumLocator,
        )

        val locator = KomgaReadiumProgression.locatorFrom(EpubBridgeCheckpointCodec.encode(checkpoint), 0.195f)!!

        assertEquals("EPUB/chapter-010.xhtml", locator.href)
        assertEquals(0.7, locator.locations?.progression)
        assertEquals("Hello world", locator.text?.highlight)
    }

    @Test
    fun ignoresPageLocators() {
        assertNull(KomgaReadiumProgression.locatorFrom("{\"page\":20}", 0.2f))
        assertNull(KomgaReadiumProgression.locatorFrom("cbz-page:3", 0.2f))
        assertNull(KomgaReadiumProgression.locatorFrom(null, 0.2f))
    }

    @Test
    fun snapsProgressionPastTheLastResourcePositionBackToIt() {
        val locator = KomgaReadiumProgression.locatorFrom(readiumLocator, 0.195f)!!

        val snapped = KomgaReadiumProgression.snapToPositions(locator, 0.195f, labPositions())!!

        assertEquals("EPUB/chapter-010.xhtml", snapped.href)
        assertEquals(0.5, snapped.locations?.progression)
        assertEquals(20, snapped.locations?.position)
        assertEquals(listOf("p3"), snapped.locations?.fragment)
        assertEquals("Hello world", snapped.text?.highlight)
    }

    @Test
    fun fallsBackToTotalProgressionWithoutAMatchingResource() {
        val snapped = KomgaReadiumProgression.snapToPositions(null, 0.215f, labPositions())!!

        assertEquals("EPUB/chapter-011.xhtml", snapped.href)
        assertEquals(0.0, snapped.locations?.progression)
        assertEquals(21, snapped.locations?.position)
        assertEquals(0.215, snapped.locations?.totalProgression!!, 1e-6)
    }

    @Test
    fun decodesLabProgressionIntoReadiumSnapshot() {
        val progression = wire.decodeFromString<KomgaR2Progression>(
            """
            {"modified":"2026-09-26T11:22:30.885Z","device":{"id":"urn:uuid:enve-probe","name":"Enve probe"},
             "locator":{"href":"EPUB/chapter-010.xhtml#p3","type":"application/xhtml+xml",
              "locations":{"progression":0.5,"totalProgression":0.2},"koboSpan":"kobo.3.3"}}
            """.trimIndent(),
        )

        val snapshot = KomgaReadiumProgression.snapshot(progression)!!

        assertEquals(0.2f, snapshot.percentage)
        assertEquals(Instant.parse("2026-09-26T11:22:30.885Z").toEpochMilli(), snapshot.updatedAt)
        assertEquals("EPUB/chapter-010.xhtml", snapshot.href)
        assertEquals(
            wire.parseToJsonElement(
                """
                {"href":"EPUB/chapter-010.xhtml","type":"application/xhtml+xml",
                 "locations":{"fragments":["p3"],"progression":0.5,"totalProgression":0.2}}
                """.trimIndent(),
            ),
            wire.parseToJsonElement(snapshot.locatorJson!!),
        )
    }

    @Test
    fun completedProgressionHasNoLocator() {
        val progression = wire.decodeFromString<KomgaR2Progression>(
            """{"modified":"2026-09-26T11:22:45.673Z","device":{"id":"","name":""},"locator":{}}""",
        )

        assertNull(KomgaReadiumProgression.snapshot(progression))
    }

    @Test
    fun onlyReflowableEpubsUseReadiumProgression() {
        val epub = wire.decodeFromString<KomgaMediaDto>(
            """{"status":"READY","mediaType":"application/epub+zip","pagesCount":100,"comment":"",
               "epubDivinaCompatible":false,"epubIsKepub":false,"mediaProfile":"EPUB"}""",
        )
        val comic = wire.decodeFromString<KomgaMediaDto>(
            """{"status":"READY","mediaType":"application/zip","pagesCount":3,"comment":"",
               "epubDivinaCompatible":false,"epubIsKepub":false,"mediaProfile":"DIVINA"}""",
        )

        assertTrue(epub.usesReadiumProgression)
        assertFalse(comic.usesReadiumProgression)
        assertFalse(epub.copy(epubDivinaCompatible = true).usesReadiumProgression)
    }

    private fun labPositions() = wire.decodeFromString<KomgaR2Positions>(
        """
        {"total":100,"positions":[
         {"href":"EPUB/chapter-010.xhtml","type":"application/xhtml+xml","locations":{"progression":0.0,"position":19,"totalProgression":0.19},"koboSpan":"kobo.1.1"},
         {"href":"EPUB/chapter-010.xhtml","type":"application/xhtml+xml","locations":{"progression":0.5,"position":20,"totalProgression":0.2},"koboSpan":"kobo.3.3"},
         {"href":"EPUB/chapter-011.xhtml","type":"application/xhtml+xml","locations":{"progression":0.0,"position":21,"totalProgression":0.21},"koboSpan":"kobo.1.1"},
         {"href":"EPUB/chapter-011.xhtml","type":"application/xhtml+xml","locations":{"progression":0.5,"position":22,"totalProgression":0.22},"koboSpan":"kobo.3.3"}]}
        """.trimIndent(),
    ).positions
}
