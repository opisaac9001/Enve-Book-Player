package com.enve.silo

import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import com.enve.core.reader.ReaderTextQuote
import com.enve.silo.dto.SiloEbookProgressResponse
import com.enve.silo.dto.SiloEbookProgressRequest
import com.enve.silo.dto.SiloFileVersionDto
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import retrofit2.Response

class SiloEpubVersionSelectionTest {
    @Test
    fun savedEpubVersionWinsOverTheDefaultEpub() {
        val versions = listOf(
            version(fileId = 2, fileName = "book.epub"),
            version(fileId = 17, fileName = "alternate.epub"),
            version(fileId = 1, fileName = "book.pdf"),
        )

        val selected = preferredSiloEpubVersion(
            versions = versions,
            savedProgressFileId = 17,
        )

        assertEquals(17, selected?.fileId)
    }

    @Test
    fun firstEpubInApiOrderIsTheDeterministicDefault() {
        val versions = listOf(
            version(fileId = 9, fileName = "late.EPUB"),
            version(fileId = 1, fileName = "book.pdf"),
            version(fileId = 6, fileName = "opaque", container = ".epub"),
            version(fileId = 4, filePath = "/library/book.epub"),
        )

        val selected = preferredSiloEpubVersion(versions)

        assertEquals(9, selected?.fileId)
    }

    @Test
    fun nonEpubVersionsAreNeverUsedAsReaderFallback() {
        val versions = listOf(
            version(fileId = 1, fileName = "book.pdf"),
            version(fileId = 2, fileName = "book.mobi"),
            version(fileId = 3, fileName = "comic.cbz", container = "zip"),
        )

        assertNull(
            preferredSiloEpubVersion(
                versions = versions,
                savedProgressFileId = 1,
            ),
        )
    }

    @Test
    fun canonicalReadiumCheckpointIsReducedToFractionForSilo() {
        val checkpoint = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            observedAt = 100,
            sourceEngine = ReaderEngineKind.READIUM,
            href = "Text/chapter.xhtml",
            resourceProgression = 0.4,
            totalProgression = 0.625,
            textQuote = ReaderTextQuote("A sentence Silo cannot restore from JSON."),
        )

        assertEquals(
            "fraction:0.625000",
            siloProgressLocation(EpubBridgeCheckpointCodec.encode(checkpoint), 0.625),
        )
    }

    @Test
    fun canonicalFoliateCheckpointKeepsItsFullCfiForSilo() {
        val checkpoint = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            observedAt = 100,
            sourceEngine = ReaderEngineKind.FOLIATE,
            href = "Text/chapter.xhtml",
            epubCfi = "epubcfi(/6/8!/4/2:10)",
            totalProgression = 0.625,
        )

        assertEquals(
            "epubcfi(/6/8!/4/2:10)",
            siloProgressLocation(EpubBridgeCheckpointCodec.encode(checkpoint), 0.625),
        )
    }

    @Test
    fun untypedCfiIsReducedToFractionForSilo() {
        assertEquals(
            "fraction:0.625000",
            siloProgressLocation("epubcfi(/6/8!/4/2:10)", 0.625),
        )
    }

    @Test
    fun activeCheckpointSuppliesTheFileIdUsedForProgressPush() {
        val checkpoint = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            providerFileId = "17",
            observedAt = 100,
            sourceEngine = ReaderEngineKind.READIUM,
            href = "Text/chapter.xhtml",
            totalProgression = 0.5,
        )

        assertEquals(
            17,
            siloActiveEpubFileId(EpubBridgeCheckpointCodec.encode(checkpoint)),
        )
        assertNull(siloActiveEpubFileId("""{"href":"Text/chapter.xhtml"}"""))
    }

    @Test
    fun progressPayloadMatchesCurrentSiloContract() {
        val payload = Json.parseToJsonElement(
            Json.encodeToString(
                SiloEbookProgressRequest(
                    fileId = 51,
                    location = "epubcfi(/6/4!/4/2:3)",
                    progress = 0.42,
                ),
            ),
        ).jsonObject

        assertEquals(setOf("file_id", "location", "progress"), payload.keys)
    }

    @Test
    fun emptyProgressObjectIsNoneButAuthAndServerErrorsPropagate() {
        val empty = requireNotNull(
            siloEbookProgressBody(
                Response.success(SiloEbookProgressResponse()),
            ),
        )
        assertNull(empty.progress)
        assertNull(
            siloEbookProgressBody(
                Response.error(404, ByteArray(0).toResponseBody()),
            ),
        )
        assertThrows(IllegalStateException::class.java) {
            siloEbookProgressBody(
                Response.error(401, ByteArray(0).toResponseBody()),
            )
        }
        assertThrows(IllegalStateException::class.java) {
            siloEbookProgressBody(
                Response.error(500, ByteArray(0).toResponseBody()),
            )
        }
    }

    @Test
    fun arbitraryJsonFromSiloIsNeverPassedToANavigator() {
        assertNull(
            siloNavigatorLocator(
                """{"href":"Text/chapter.xhtml","locations":{"progression":0.5}}""",
                0.5,
            ),
        )
        assertNull(siloNavigatorLocator("fraction:0.500000", 0.5))
        assertNull(siloNavigatorLocator("epubcfi(/6/8)", 0.5))
        assertEquals(
            """{"href":"","type":"application/xhtml+xml","locations":{"cfi":"epubcfi(/6/8!/4/2:10)","progression":0.5,"totalProgression":0.5}}""",
            siloNavigatorLocator("epubcfi(/6/8!/4/2:10)", 0.5),
        )
    }

    private fun version(
        fileId: Int,
        fileName: String? = null,
        filePath: String? = null,
        container: String? = null,
    ) = SiloFileVersionDto(
        fileId = fileId,
        fileName = fileName,
        filePath = filePath,
        container = container,
    )
}
