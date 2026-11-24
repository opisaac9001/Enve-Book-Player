package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.dto.LegacyBookloreBookDto
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GrimmoryBookRecordMappingTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private fun record(body: String) = json.decodeFromString(LegacyBookloreBookDto.serializer(), body)

    @Test
    fun detailRecordKeepsNestedMetadataAndEveryFormatFile() {
        val detail = record(
            """{"id":12,"libraryId":3,"lastReadTime":"2026-11-14T10:00:00Z","readStatus":"READING",
                "metadata":{"title":"Nested","subtitle":"Sub","authors":["A","B"],"seriesName":"S","seriesNumber":2.0,"description":"D"},
                "primaryFile":{"id":120,"bookType":"EPUB","fileName":"nested.epub"},
                "alternativeFormats":[{"id":121,"bookType":"AUDIOBOOK","fileName":"nested.m4b"}],
                "shelves":[{"id":4,"name":"Favorites","bookCount":1}],
                "epubProgress":{"cfi":"epubcfi(/6/2!/4/2)","href":"c1.xhtml","percentage":37.5}}""",
        ).toBookDetailDto()

        assertEquals("Nested", detail.title)
        assertEquals("Sub", detail.subtitle)
        assertEquals(listOf("A", "B"), detail.authors)
        assertEquals("2.0", detail.seriesNumber)
        assertEquals(listOf("120", "121"), detail.files.orEmpty().map { it.id })
        assertEquals(listOf("EPUB", "AUDIOBOOK"), detail.fileTypes)
        assertEquals(true, detail.files.orEmpty().first().isPrimary)
        assertEquals("4", detail.shelves.orEmpty().single().id)
        assertTrue(detail.hasAudioFormat())
        assertTrue(detail.hasEbookFormat())
        assertEquals(0.375f, grimmoryPercentFraction(detail.readProgress) ?: 0f, 0.0001f)
    }

    @Test
    fun koreaderPercentIsRescaledToTheFractionTheSnapshotsExpect() {
        val detail = record(
            """{"id":13,"primaryFile":{"id":130,"bookType":"EPUB"},"koreaderProgress":{"percentage":64.0}}""",
        ).toBookDetailDto()

        assertEquals(0.64f, detail.koreaderProgress?.percentage ?: 0f, 0.0001f)
        assertEquals(0.64f, grimmoryReadProgressFraction(detail.readProgress, koreaderProgressPresent = true) ?: 0f, 0.0001f)
        val snapshot = requireNotNull(grimmoryEbookProgressSnapshot(detail.toProgressDto(), updatedAtMs = 1L))
        assertEquals(0.64f, snapshot.percentage, 0.0001f)
    }

    @Test
    fun hiddenAudiobookProgressCannotMarkTheEbookFinished() {
        val detail = record(
            """{"id":14,"readStatus":"READ","primaryFile":{"id":140,"bookType":"EPUB"},
                "alternativeFormats":[{"id":141,"bookType":"AUDIOBOOK"}],"epubProgress":{"percentage":20.0}}""",
        ).toBookDetailDto()
        val body = detail.toProgressDto()

        assertNull(body.audiobookProgress)
        val guarded = requireNotNull(
            grimmoryEbookProgressSnapshot(body, updatedAtMs = 1L, audioProgressPresent = detail.hasAudioFormat()),
        )
        assertFalse(guarded.finished)
        assertEquals(0.2f, guarded.percentage, 0.0001f)
    }

    @Test
    fun browseRecordWithBothFormatsKeepsTheEbookPrimaryAndAudioCompanion() {
        val summary = record(
            """{"id":15,"metadata":{"title":"Pair"},"primaryFile":{"id":151,"bookType":"AUDIOBOOK","fileName":"pair.m4b"},
                "alternativeFormats":[{"id":150,"bookType":"EPUB","fileName":"pair.epub"}]}""",
        ).toCatalogSummary(fallbackLibraryId = "1")

        assertEquals("EPUB", summary.primaryFileType)
        assertEquals("pair.epub", summary.primaryFileName)
        assertEquals(listOf("151"), summary.alternativeFormats.orEmpty().map { it.id })
        assertEquals("1", summary.libraryId)
        assertTrue(summary.hasAudioFormat())
    }
}
