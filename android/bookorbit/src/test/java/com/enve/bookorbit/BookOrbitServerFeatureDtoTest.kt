package com.enve.bookorbit

import com.enve.bookorbit.dto.BookOrbitAchievementCatalogueDto
import com.enve.bookorbit.dto.BookOrbitAnnotationHubPageDto
import com.enve.bookorbit.dto.BookOrbitProgressFunnelComparisonDto
import com.enve.bookorbit.dto.BookOrbitReadingSessionsPageDto
import com.enve.bookorbit.dto.BookOrbitRecommendationDto
import com.enve.bookorbit.dto.BookOrbitSourceDistributionDto
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BookOrbitServerFeatureDtoTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun readingSessionsCarryFormatAndSource() {
        val page = json.decodeFromString<BookOrbitReadingSessionsPageDto>(
            """
            {"items":[
              {"id":1,"startedAt":"2026-08-12T10:00:00Z","endedAt":"2026-08-12T10:30:00Z","durationSeconds":1800,"format":"EPUB","source":"koreader"},
              {"id":2,"startedAt":"2026-08-12T11:00:00Z","endedAt":"2026-08-12T11:30:00Z","durationSeconds":1800,"format":"M4B","source":"web"},
              {"id":3,"startedAt":"2026-08-12T12:00:00Z","endedAt":"2026-08-12T12:30:00Z","durationSeconds":1800}
            ],"total":3,"page":1,"pageSize":100}
            """.trimIndent(),
        )

        assertEquals("EPUB", page.items[0].format)
        assertEquals("koreader", page.items[0].source)
        assertEquals("M4B", page.items[1].format)
        assertNull(page.items[2].format)
        assertNull(page.items[2].source)
    }

    @Test
    fun decodesAchievementCatalogue() {
        val catalogue = json.decodeFromString<BookOrbitAchievementCatalogueDto>(
            """
            {"categories":[{"key":"reading","label":"Reading","earnedCount":1,"totalCount":2,"achievements":[
              {"key":"first-book","groupKey":"books","tier":1,"category":"reading","name":"First book","description":"Finish a book","iconName":"Book","rarity":"common","threshold":1,"hidden":false,"sortOrder":0,"earned":true,"awardedAt":"2026-01-02T03:04:05Z","context":{"bookId":9},"currentProgress":1},
              {"key":"ten-books","groupKey":"books","tier":2,"category":"reading","name":"Ten books","description":"Finish ten","iconName":"Book","rarity":"rare","threshold":10,"hidden":false,"sortOrder":1,"earned":false,"awardedAt":null,"context":null,"currentProgress":4}
            ]}],"totalEarned":1,"totalAvailable":2}
            """.trimIndent(),
        )

        val achievements = catalogue.categories.single().achievements
        assertEquals(2, catalogue.totalAvailable)
        assertTrue(achievements[0].earned)
        assertEquals(10.0, achievements[1].threshold!!, 0.0)
        assertEquals(4.0, achievements[1].currentProgress!!, 0.0)
    }

    @Test
    fun decodesAnnotationHubPage() {
        val page = json.decodeFromString<BookOrbitAnnotationHubPageDto>(
            """
            {"items":[{"id":5,"bookId":2,"cfi":"epubcfi(/6/2!)","jumpFileId":null,"pageno":null,"text":"A line","color":"yellow","style":"highlight","note":"why","chapterTitle":"One","origin":"koreader","positionStatus":"exact","chapterIndex":0,"createdAt":"2026-08-12T10:00:00Z","deletedAt":null,"bookTitle":"Title","author":"Author","jumpFileFormat":"EPUB"}],
             "total":1,"page":1,"pageSize":40,
             "stats":{"books":1,"withNotes":1,"originBreakdown":[{"origin":"koreader","count":1}]}}
            """.trimIndent(),
        )

        val item = page.items.single()
        assertEquals("A line", item.text)
        assertEquals("koreader", item.origin)
        assertNull(item.deletedAt)
        assertEquals(1, page.stats.books)
        assertEquals(1, page.stats.originBreakdown.single().count)
    }

    @Test
    fun decodesStatisticsPayloads() {
        val distribution = json.decodeFromString<BookOrbitSourceDistributionDto>(
            """{"totalSeconds":900,"slices":[{"bucket":"bookorbit","readingSeconds":600},{"bucket":"kobo","readingSeconds":300}]}""",
        )
        val funnel = json.decodeFromString<BookOrbitProgressFunnelComparisonDto>(
            """{"days":30,"current":{"started":10,"reached25":8,"reached50":5,"reached75":3,"completed":2},"previous":null}""",
        )
        val recommendation = json.decodeFromString<BookOrbitRecommendationDto>(
            """{"id":4,"title":"Next","coverAspectRatio":"2:3","updatedAt":null,"seriesIndex":2.0,"hasCover":true,"authors":["Ada"],"isAudiobook":false}""",
        )

        assertEquals(900L, distribution.totalSeconds)
        assertEquals("kobo", distribution.slices[1].bucket)
        assertEquals(2, funnel.current.completed)
        assertNull(funnel.previous)
        assertEquals(2.0, recommendation.seriesIndex!!, 0.0)
        assertTrue(recommendation.hasCover)
    }
}
