package com.enve.app.data.remote.dto

import com.enve.app.data.repository.kavitaPageNum
import com.enve.app.data.repository.kavitaReaderFormat
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KavitaCatalogDtoTest {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = true
    }

    @Test
    fun decodesLibrariesArray() {
        val libraries = json.decodeFromString<List<KavitaLibraryDto>>(
            """
            [{"id":1,"name":"Books","type":2,"lastScanned":"2026-09-20T10:00:00","folders":["/books"],
              "coverImage":null,"libraryFileTypes":[{"libraryId":1,"fileTypeGroup":3}]},
             {"id":2,"name":"Comics","type":1,"folders":["/comics"]}]
            """,
        )

        assertEquals(listOf(1 to "Books", 2 to "Comics"), libraries.map { it.id to it.name })
        assertEquals(listOf(2, 1), libraries.map { it.type })
    }

    @Test
    fun decodesSeriesPage() {
        val series = json.decodeFromString<List<KavitaSeriesDto>>(
            """
            [{"id":20,"name":"Two Centuries of Costume","libraryId":1,"libraryName":"Books","format":3,
              "pages":20,"pagesRead":8,"created":"2026-08-18T00:02:37.3398405",
              "latestReadDate":"2026-09-21T20:55:41.3493567","coverImage":"series20.png"},
             {"id":30,"name":"Image Regression","libraryId":2,"format":0,"pages":6,"pagesRead":0,
              "created":"2026-09-23T22:18:19.0419796","latestReadDate":null}]
            """,
        )

        assertEquals(listOf(20, 30), series.map { it.id })
        assertEquals(KavitaMangaFormat.EPUB, series[0].format)
        assertEquals(8, series[0].pagesRead)
        assertEquals(2, series[1].libraryId)
        assertNull(series[1].latestReadDate)
    }

    @Test
    fun decodesVolumesWithChapters() {
        val volumes = json.decodeFromString<List<KavitaVolumeDto>>(
            """
            [{"id":36,"minNumber":-100000,"name":"-100000","pages":6,
              "chapters":[{"id":57,"range":"1","pages":3,"files":[]},{"id":58,"range":"2","pages":3}]}]
            """,
        )

        assertEquals(57, volumes.first().chapters.first().id)
        assertEquals(listOf(3, 3), volumes.first().chapters.map { it.pages })
    }

    @Test
    fun encodesLibraryFilter() {
        val body = json.parseToJsonElement(json.encodeToString(KavitaSeriesFilterDto.forLibrary("2"))).jsonObject
        val statement = body.getValue("statements").jsonArray.single().jsonObject

        assertEquals(19, statement.getValue("field").jsonPrimitive.int)
        assertEquals("2", statement.getValue("value").jsonPrimitive.content)
        assertTrue(body.containsKey("sortOptions"))
        assertTrue(
            json.encodeToString(KavitaSeriesFilterDto.forLibrary(null)).contains("\"statements\":[]"),
        )
    }

    @Test
    fun decodesReaderProgress() {
        val saved = json.decodeFromString<KavitaProgressDto>(
            """{"volumeId":23,"chapterId":25,"pageNum":8,"seriesId":20,"libraryId":1,"bookScrollId":null,"lastModifiedUtc":"2026-09-21T20:55:41.1785107"}""",
        )
        val unread = json.decodeFromString<KavitaProgressDto>(
            """{"volumeId":0,"chapterId":57,"pageNum":0,"seriesId":0,"libraryId":0,"bookScrollId":null,"lastModifiedUtc":"0001-01-01T00:00:00"}""",
        )

        assertEquals(8, saved.pageNum)
        assertEquals("2026-09-21T20:55:41.1785107", saved.lastModifiedUtc)
        assertEquals(0, unread.pageNum)
    }

    @Test
    fun encodesSaveProgressWithoutTimestamp() {
        val body = json.encodeToString(
            KavitaSaveProgressDto(seriesId = 20, libraryId = 1, volumeId = 23, chapterId = 25, pageNum = 8),
        )

        assertEquals("""{"seriesId":20,"libraryId":1,"volumeId":23,"chapterId":25,"pageNum":8}""", body)
        assertFalse(body.contains("lastModifiedUtc"))
    }

    @Test
    fun mapsPercentageToPageNum() {
        assertEquals(8, kavitaPageNum(0.4f, 20))
        assertEquals(1, kavitaPageNum(1f / 3f, 3))
        assertEquals(0, kavitaPageNum(0f, 3))
        assertEquals(3, kavitaPageNum(0.995f, 3))
        assertEquals(20, kavitaPageNum(1.2f, 20))
    }

    @Test
    fun mapsSeriesFormatToReaderFormat() {
        assertEquals("CBZ", kavitaReaderFormat(KavitaMangaFormat.IMAGE))
        assertEquals("CBX", kavitaReaderFormat(KavitaMangaFormat.ARCHIVE))
        assertEquals("EPUB", kavitaReaderFormat(KavitaMangaFormat.EPUB))
        assertEquals("PDF", kavitaReaderFormat(KavitaMangaFormat.PDF))
        assertNull(kavitaReaderFormat(KavitaMangaFormat.UNKNOWN))
    }
}
