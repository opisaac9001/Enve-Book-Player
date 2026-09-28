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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class BookOrbitEbookProgressTest {
    private val transportJson = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = true
    }

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
    fun aPercentageOnlyWriteOmitsCfiInsteadOfErasingTheServerAnchor() {
        val payload = Json.parseToJsonElement(
            transportJson.encodeToString(
                BookOrbitEbookProgressRequest.serializer(),
                BookOrbitEbookProgressRequest(percentage = 42.0),
            ),
        ).jsonObject

        assertFalse(payload.containsKey("cfi"))
        assertEquals(42.0, payload.getValue("percentage").jsonPrimitive.content.toDouble(), 0.0001)
    }

    @Test
    fun anExactWriteStillCarriesItsCfi() {
        val payload = Json.parseToJsonElement(
            transportJson.encodeToString(
                BookOrbitEbookProgressRequest.serializer(),
                BookOrbitEbookProgressRequest(percentage = 42.0, cfi = "epubcfi(/6/8!/4/2:10)"),
            ),
        ).jsonObject

        assertEquals("epubcfi(/6/8!/4/2:10)", payload.getValue("cfi").jsonPrimitive.content)
    }

    @Test
    fun aPercentageOnlyPullOffersNoLocatorToReplaceTheLocalOne() {
        for (serverCfi in listOf(null, "", "epubcfi(/4/2:10)", "invalid")) {
            val snapshot = bookOrbitEbookSnapshot(serverCfi, 42.0, 500L)
            assertNull(snapshot.locatorJson)
            assertNull(snapshot.epubCfi)
            assertEquals(0.42f, snapshot.percentage, 0.0001f)
            assertEquals(500L, snapshot.updatedAt!!)
        }
    }

    @Test
    fun anExactServerCfiBecomesTheSnapshotLocator() {
        val snapshot = bookOrbitEbookSnapshot("epubcfi(/6/8!/4/2:10)", 42.0, 500L)

        assertEquals("epubcfi(/6/8!/4/2:10)", snapshot.epubCfi)
        assertEquals("epubcfi(/6/8!/4/2:10)", bookOrbitFoliateCfi(snapshot.locatorJson))
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
