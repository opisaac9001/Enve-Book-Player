package com.enve.bookorbit

import com.enve.bookorbit.dto.BookOrbitEbookProgressRequest
import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BookOrbitEbookProgressTest {
    @Test
    fun serverCfiSurvivesCacheRestoreAndUpload() {
        val cfi = "epubcfi(/6/8!/4/2:10)"
        val cached = bookOrbitEpubLocator(cfi, 0.42f)
        val checkpoint = EpubBridgeCheckpointCodec.fromReadiumLocator(
            cached, "publication", "34", 1L, 0L, 500L,
        )!!
        assertEquals(ReaderEngineKind.FOLIATE, checkpoint.sourceEngine)
        assertEquals(cfi, checkpoint.epubCfi)
        assertEquals(cfi, bookOrbitFoliateCfi(cached))
        assertEquals(cfi, bookOrbitFoliateCfi(EpubBridgeCheckpointCodec.encode(checkpoint)))
        assertNull(checkpoint.forPublication("different-publication", "34").epubCfi)
    }

    @Test
    fun missingOrPartialServerCfiDoesNotBecomeAnExactLocation() {
        for (cfi in listOf(null, "epubcfi(/4/2:10)", "invalid")) {
            assertNull(bookOrbitFoliateCfi(bookOrbitEpubLocator(cfi, 0.42f)))
        }
    }

    @Test
    fun foliateCheckpointWritesItsExactCfi() {
        val cfi = bookOrbitFoliateCfi(
            EpubBridgeCheckpointCodec.encode(
                EpubBridgeCheckpoint(
                    publicationSha256 = "hash",
                    providerFileId = "42",
                    observedAt = 1L,
                    sourceEngine = ReaderEngineKind.FOLIATE,
                    href = "Text/chapter.xhtml",
                    epubCfi = "epubcfi(/6/8!/4/2:10)",
                ),
            ),
        )
        val payload = Json.parseToJsonElement(
            Json.encodeToString(BookOrbitEbookProgressRequest(percentage = 42.0, cfi = cfi)),
        ).jsonObject

        assertEquals("epubcfi(/6/8!/4/2:10)", payload.getValue("cfi").jsonPrimitive.content)
    }

    @Test
    fun readiumAndRawCfisAreNotClaimedAsFoliateLocations() {
        val readium = EpubBridgeCheckpointCodec.encode(
            EpubBridgeCheckpoint(
                publicationSha256 = "hash",
                observedAt = 1L,
                sourceEngine = ReaderEngineKind.READIUM,
                epubCfi = "epubcfi(/6/8!/4/2:10)",
            ),
        )

        assertNull(bookOrbitFoliateCfi(readium))
        assertNull(bookOrbitFoliateCfi("epubcfi(/6/8!/4/2:10)"))
    }
}
