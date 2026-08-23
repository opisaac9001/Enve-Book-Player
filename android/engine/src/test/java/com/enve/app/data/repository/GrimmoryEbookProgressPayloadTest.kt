package com.enve.app.data.repository

import com.enve.app.data.remote.dto.GrimmoryUpdateProgressRequest
import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GrimmoryEbookProgressPayloadTest {

    @Test
    fun readiumCheckpointUsesPercentOnlyOfficialFields() {
        val payload = grimmoryEbookFileProgress(
            bookFileId = 84,
            totalProgression = 0.72f,
            checkpointValue = EpubBridgeCheckpointCodec.encode(
                checkpoint(
                    sourceEngine = ReaderEngineKind.READIUM,
                    href = "chapter-4.xhtml",
                    epubCfi = "epubcfi(/6/8!/4/2/6)",
                    resourceProgression = 0.37,
                ),
            ),
        )

        assertEquals(84L, payload.bookFileId)
        assertEquals(72.0, payload.progressPercent, 0.0001)
        assertNull(payload.positionData)
        assertNull(payload.positionHref)
        assertNull(payload.ttsPositionCfi)
        assertNull(payload.contentSourceProgressPercent)
    }

    @Test
    fun foliateCheckpointUsesExactCfiHrefAndResourceProgress() {
        val payload = grimmoryEbookFileProgress(
            bookFileId = 23,
            totalProgression = 0.61f,
            checkpointValue = EpubBridgeCheckpointCodec.encode(
                checkpoint(
                    sourceEngine = ReaderEngineKind.FOLIATE,
                    href = "Text/chapter-12.xhtml",
                    epubCfi = "epubcfi(/6/24!/4/8/2:15)",
                    resourceProgression = 0.3125,
                ),
            ),
        )

        assertEquals("epubcfi(/6/24!/4/8/2:15)", payload.positionData)
        assertEquals("Text/chapter-12.xhtml", payload.positionHref)
        assertEquals(31.25, payload.contentSourceProgressPercent!!, 0.0001)
        assertEquals(61.0, payload.progressPercent, 0.0001)
    }

    @Test
    fun foliateCollapsedRangeCfiIsPreservedForGrimmory() {
        val cfi = "epubcfi(/6/2!/2/2,,/6/1:44)"
        val payload = grimmoryEbookFileProgress(
            bookFileId = 104,
            totalProgression = 0.0084f,
            checkpointValue = EpubBridgeCheckpointCodec.encode(
                checkpoint(
                    sourceEngine = ReaderEngineKind.FOLIATE,
                    href = "text/titlepage.xhtml",
                    epubCfi = cfi,
                    resourceProgression = 0.5,
                ),
            ),
        )

        assertEquals(cfi, payload.positionData)
        assertEquals("text/titlepage.xhtml", payload.positionHref)
        assertEquals(50.0, payload.contentSourceProgressPercent!!, 0.0001)
    }

    @Test
    fun malformedOrUnprovenCfiUsesPercentOnly() {
        val malformed = grimmoryEbookFileProgress(
            bookFileId = 31,
            totalProgression = 0.5f,
            checkpointValue = EpubBridgeCheckpointCodec.encode(
                checkpoint(
                    sourceEngine = ReaderEngineKind.FOLIATE,
                    href = "chapter-3.xhtml",
                    epubCfi = "/6/6!/4/2",
                    resourceProgression = 0.5,
                ),
            ),
        )
        val raw = grimmoryEbookFileProgress(
            bookFileId = 7,
            totalProgression = 0.19f,
            checkpointValue = "epubcfi(/6/4!/4/2/8)",
        )

        for (payload in listOf(malformed, raw)) {
            assertNull(payload.positionData)
            assertNull(payload.positionHref)
            assertNull(payload.contentSourceProgressPercent)
        }
    }

    @Test
    fun wirePayloadMatchesCurrentGrimmoryAppContract() {
        val request = GrimmoryUpdateProgressRequest(
            fileProgress = grimmoryEbookFileProgress(
                bookFileId = 107,
                totalProgression = 0.42f,
                checkpointValue = EpubBridgeCheckpointCodec.encode(
                    checkpoint(
                        sourceEngine = ReaderEngineKind.FOLIATE,
                        href = "chapter.xhtml",
                        epubCfi = "epubcfi(/6/4!/4/2:3)",
                        resourceProgression = 0.18,
                    ),
                ),
            ),
        )
        val root = Json.parseToJsonElement(Json.encodeToString(request)).jsonObject
        val fileProgress = root.getValue("fileProgress").jsonObject

        assertEquals(setOf("fileProgress"), root.keys)
        assertEquals(
            setOf(
                "bookFileId",
                "positionData",
                "positionHref",
                "progressPercent",
                "contentSourceProgressPercent",
            ),
            fileProgress.keys,
        )
        assertEquals(107L, fileProgress.getValue("bookFileId").jsonPrimitive.content.toLong())
        assertEquals(
            "epubcfi(/6/4!/4/2:3)",
            fileProgress.getValue("positionData").jsonPrimitive.content,
        )
        assertFalse("positionType" in fileProgress)
        assertFalse("readiumLocatorJson" in fileProgress)
        assertFalse("textHighlight" in fileProgress)
        assertTrue("ttsPositionCfi" !in fileProgress)
    }

    private fun checkpoint(
        sourceEngine: ReaderEngineKind,
        href: String?,
        epubCfi: String?,
        resourceProgression: Double?,
    ) = EpubBridgeCheckpoint(
        publicationSha256 = "abc123",
        providerFileId = "55",
        observedAt = 1_700_000_000_000,
        sourceEngine = sourceEngine,
        href = href,
        epubCfi = epubCfi,
        resourceProgression = resourceProgression,
        totalProgression = 0.8,
    )
}
