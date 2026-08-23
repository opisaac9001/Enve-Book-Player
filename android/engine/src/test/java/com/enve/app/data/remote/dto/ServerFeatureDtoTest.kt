package com.enve.app.data.remote.dto

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ServerFeatureDtoTest {
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    @Test
    fun decodesKavitaProfileStatBar() {
        val bar = json.decodeFromString<KavitaProfileStatBarDto>(
            """{"booksRead":12,"comicsRead":3,"pagesRead":4200,"wordsRead":980000,"authorsRead":9,"reviews":2,"ratings":5}""",
        )

        assertEquals(12, bar.booksRead)
        assertEquals(980000, bar.wordsRead)
    }

    @Test
    fun decodesKavitaReadStatisticsWithNullLastActive() {
        val stats = json.decodeFromString<KavitaUserReadStatisticsDto>(
            """{"totalPagesRead":4200,"totalWordsRead":980000,"timeSpentReading":37,"lastActiveUtc":null,"avgHoursPerWeekSpentReading":2.5}""",
        )

        assertEquals(37L, stats.timeSpentReading)
        assertEquals(2.5, stats.avgHoursPerWeekSpentReading, 0.0001)
        assertNull(stats.lastActiveUtc)
    }

    @Test
    fun decodesKavitaAnnotations() {
        val annotations = json.decodeFromString<List<KavitaAnnotationDto>>(
            """
            [{"id":31,"xPath":"/html/body","selectedText":"A line","commentPlainText":"why it matters",
              "chapterTitle":"Chapter 2","seriesName":"Piranesi","pageNumber":14,
              "createdUtc":"2025-08-12T10:00:00","lastModifiedUtc":"2025-08-12T10:00:00",
              "chapterId":4,"volumeId":2,"seriesId":9,"libraryId":1,"ownerUserId":1}]
            """.trimIndent(),
        )

        val annotation = annotations.single()
        assertEquals("A line", annotation.selectedText)
        assertEquals("Piranesi", annotation.seriesName)
        assertEquals(14, annotation.pageNumber)
    }

    @Test
    fun decodesKavitaAccount() {
        val account = json.decodeFromString<KavitaAccountDto>(
            """{"id":7,"username":"reader","email":"x@example.invalid","roles":["Admin"],"token":"redacted"}""",
        )

        assertEquals(7, account.id)
        assertEquals("reader", account.username)
    }

    @Test
    fun decodesGrimmoryRecommendationsByBookId() {
        val recommendations = json.decodeFromString<List<GrimmoryRecommendationDto>>(
            """[{"book":{"id":42,"title":"Next"},"similarityScore":0.91},{"book":{"id":"43"},"similarityScore":0.4}]""",
        )

        assertEquals(listOf("42", "43"), recommendations.mapNotNull { it.book?.id })
        assertTrue(recommendations.first().similarityScore > recommendations.last().similarityScore)
    }
}
