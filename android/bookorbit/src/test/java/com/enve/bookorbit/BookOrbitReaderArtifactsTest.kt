package com.enve.bookorbit

import com.enve.bookorbit.dto.BookOrbitAnnotationDto
import com.enve.bookorbit.dto.BookOrbitBookmarkDto
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.ReaderAnnotation
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import retrofit2.Response

class BookOrbitReaderArtifactsTest {

    private val serverJson = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = true
    }

    private fun annotation(
        id: String = "local-1",
        kind: AnnotationKind = AnnotationKind.HIGHLIGHT,
        media: AnnotationMedia = AnnotationMedia.EPUB,
        cfi: String? = "epubcfi(/6/8!/4/2:10)",
        selectedText: String = "a quoted line",
        serverId: String? = null,
        audioPositionMs: Long? = null,
        deletedAt: Long? = null,
        providerSource: String = BOOKORBIT_PROVIDER_SOURCE,
    ) = ReaderAnnotation(
        id = id,
        bookId = "7",
        kind = kind.name,
        media = media.name,
        cfi = cfi,
        selectedText = selectedText,
        audioPositionMs = audioPositionMs,
        serverId = serverId,
        deletedAt = deletedAt,
        providerSource = providerSource,
    )

    @Test
    fun unsupportedLocalArtifactsAreRejectedRatherThanAccepted() {
        val unsupported = listOf(
            annotation(media = AnnotationMedia.PDF),
            annotation(media = AnnotationMedia.CBZ),
            annotation(cfi = null),
            annotation(cfi = "   "),
            annotation(selectedText = ""),
            annotation(kind = AnnotationKind.BOOKMARK, cfi = null),
            annotation(kind = AnnotationKind.BOOKMARK, media = AnnotationMedia.AUDIOBOOK, cfi = null),
        )
        for (artifact in unsupported) {
            assertEquals(BookOrbitArtifactPush.UNSUPPORTED, artifact.bookOrbitArtifactPush())
        }
        assertEquals(
            BookOrbitArtifactPush.FOREIGN,
            annotation(providerSource = "koreader").bookOrbitArtifactPush(),
        )
    }

    @Test
    fun supportedLocalArtifactsKeepTheirPushRoute() {
        assertEquals(
            BookOrbitArtifactPush.CREATE_HIGHLIGHT,
            annotation().bookOrbitArtifactPush(),
        )
        assertEquals(
            BookOrbitArtifactPush.UPDATE_HIGHLIGHT,
            annotation(cfi = null, selectedText = "", serverId = "31").bookOrbitArtifactPush(),
        )
        assertEquals(
            BookOrbitArtifactPush.BOOKMARK,
            annotation(kind = AnnotationKind.BOOKMARK).bookOrbitArtifactPush(),
        )
        assertEquals(
            BookOrbitArtifactPush.BOOKMARK,
            annotation(
                kind = AnnotationKind.BOOKMARK,
                media = AnnotationMedia.AUDIOBOOK,
                cfi = null,
                audioPositionMs = 12_500L,
            ).bookOrbitArtifactPush(),
        )
        assertEquals(
            BookOrbitArtifactPush.DELETE,
            annotation(serverId = "31", deletedAt = 1_000L).bookOrbitArtifactPush(),
        )
    }

    @Test
    fun koreaderOriginRowsDecodeAndMapWithoutFailingTheBookPull() {
        val payload = """
            [
              {"id":7,"bookId":3,"cfi":null,"pageno":42,"text":null,"color":null,"style":null,
               "note":"synced from koreader","chapterTitle":null,"origin":"koreader","createdAt":null},
              {"id":8},
              {"id":9,"cfi":"epubcfi(/6/8!/4/2:10)","text":"quoted","color":"#FFEE58","style":"underline",
               "createdAt":"2026-01-02T03:04:05Z"}
            ]
        """.trimIndent()

        val rows = serverJson.decodeFromString(ListSerializer(BookOrbitAnnotationDto.serializer()), payload)
        assertEquals(3, rows.size)

        val mapped = rows.mapNotNull { it.toReaderAnnotationOrNull("7") }
        assertEquals(listOf("bookorbit:7", "bookorbit:9"), mapped.map { it.id })

        val koreader = mapped.first()
        assertNull(koreader.cfi)
        assertEquals(AnnotationMedia.PDF.name, koreader.media)
        assertEquals(41, koreader.pdfPage)
        assertEquals("synced from koreader", koreader.note)
        assertEquals("7", koreader.serverId)
        assertEquals(BOOKORBIT_PROVIDER_SOURCE, koreader.providerSource)

        val exact = mapped.last()
        assertEquals("epubcfi(/6/8!/4/2:10)", exact.cfi)
        assertEquals("#FFEE58", exact.colorHex)
        assertEquals(1_767_323_045_000L, exact.createdAt)
    }

    @Test
    fun anchorlessBookmarkRowsAreSkippedInsteadOfStored() {
        val payload = """
            [{"id":4},{"id":5,"cfi":"epubcfi(/6/8!/4/2:10)"},{"id":6,"positionSeconds":12.5,"title":null}]
        """.trimIndent()

        val mapped = serverJson.decodeFromString(ListSerializer(BookOrbitBookmarkDto.serializer()), payload)
            .mapNotNull { it.toReaderAnnotationOrNull("7") }

        assertEquals(listOf("bookorbit:bookmark:5", "bookorbit:bookmark:6"), mapped.map { it.id })
        assertEquals(AnnotationMedia.EPUB.name, mapped.first().media)
        assertEquals(AnnotationMedia.AUDIOBOOK.name, mapped.last().media)
        assertEquals(12_500L, mapped.last().audioPositionMs!!)
    }

    @Test
    fun anUnsupportedArtifactEndpointDoesNotFailTheOtherOne() {
        assertEquals(listOf(1, 2), bookOrbitOptionalRows("rows failed", Response.success(listOf(1, 2))))
        assertEquals(emptyList<Int>(), bookOrbitOptionalRows("rows failed", errorResponse(404)))
        assertEquals(emptyList<Int>(), bookOrbitOptionalRows("rows failed", errorResponse(405)))
        assertEquals(emptyList<Int>(), bookOrbitOptionalRows("rows failed", errorResponse(501)))
    }

    @Test(expected = IllegalStateException::class)
    fun aFailingArtifactEndpointStillRaises() {
        bookOrbitOptionalRows("rows failed", errorResponse(500))
    }

    private fun errorResponse(code: Int): Response<List<Int>> =
        Response.error(code, "".toResponseBody("application/json".toMediaType()))
}
