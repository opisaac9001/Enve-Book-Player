package com.enve.storyteller

import com.enve.storyteller.dto.StorytellerAlignmentFacetsDto
import com.enve.storyteller.dto.StorytellerAlignmentReportDto
import com.enve.storyteller.dto.StorytellerBookDto
import com.enve.storyteller.dto.StorytellerShelfDto
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StorytellerHubDtoTest {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    @Test
    fun decodesShelvesWithArbitraryFilterAndSkipsMalformedEntries() {
        val payload = """
            [
              "broken",
              {
                "uuid": "shelf-1",
                "name": "Favorites",
                "description": "Best of",
                "filter": {"authors": ["Le Guin"], "minRating": 4},
                "orderBy": "createdAt",
                "orderDirection": "desc",
                "icon": "star",
                "color": "#F5921A",
                "books": [
                  {"bookUuid": "b1", "position": 0},
                  {"bookUuid": "b2"}
                ]
              }
            ]
        """.trimIndent()

        val decoded = decodeLenientStorytellerArray<StorytellerShelfDto>(json, payload)

        assertEquals(1, decoded.skippedCount)
        val shelf = decoded.values.single()
        assertEquals("shelf-1", shelf.uuid)
        assertEquals("Favorites", shelf.name)
        assertEquals(2, shelf.books?.size)
        assertEquals("b2", shelf.books?.get(1)?.bookUuid)
        assertNull(shelf.books?.get(1)?.position)
        assertEquals(2, shelf.filter?.jsonObject?.size)
    }

    @Test
    fun decodesAlignmentFacets() {
        val facets = json.decodeFromString<StorytellerAlignmentFacetsDto>(
            """{"grades":{"A":12,"B":3,"F":1},"total":16,"muted":2}""",
        )

        assertEquals(12, facets.grades["A"])
        assertEquals(16, facets.total)
        assertEquals(2, facets.muted)
    }

    @Test
    fun decodesEnrichedAlignmentReport() {
        val report = json.decodeFromString<StorytellerAlignmentReportDto>(
            """
            {
              "bookUuid": "b1",
              "bookTitle": "Piranesi",
              "reportUuid": "r1",
              "createdAt": "2026-08-01T12:00:00.000Z",
              "summary": {
                "grade": "B",
                "score": 87.0,
                "chapters": 24,
                "missingSentences": 31,
                "mutedChapters": 1,
                "failedChapters": 0,
                "unalignedAudio": 2
              },
              "totalAudioDuration": 44120.5,
              "alignedAudioDuration": 43000.0,
              "totalSentences": 5200,
              "alignedSentences": 5169,
              "significantChapters": 22,
              "chapters": [
                {
                  "href": "ch1.xhtml",
                  "label": "1",
                  "title": "The House",
                  "chapterSentenceCount": 210,
                  "alignedSentenceCount": 208,
                  "coverage": 0.99,
                  "delta": -12,
                  "deltaPct": -0.02,
                  "flagged": true,
                  "flags": [{"label": "short audio", "tone": "moderate"}],
                  "markedOk": false,
                  "excludedFromScore": false
                }
              ],
              "unalignedChapters": [
                {"href": "toc.xhtml", "label": "Contents", "reason": "no audio", "preview": "Table of…", "intended": true}
              ],
              "unalignedAudioFiles": [
                {"filepath": "extras/interview.mp3", "title": "Interview", "duration": 620.0, "transcription": "So tell us…", "excluded": false}
              ]
            }
            """.trimIndent(),
        )

        assertEquals("b1", report.bookUuid)
        assertEquals("r1", report.reportUuid)
        assertEquals("B", report.summary.grade)
        assertEquals(31, report.summary.missingSentences)
        assertEquals(44120.5, report.totalAudioDuration, 0.001)
        assertEquals(5169, report.alignedSentences)
        val chapter = report.chapters.single()
        assertEquals("The House", chapter.title)
        assertEquals(true, chapter.flagged)
        assertEquals("moderate", chapter.flags.single().tone)
        assertEquals(true, report.unalignedChapters.single().intended)
        assertEquals("Interview", report.unalignedAudioFiles.single().title)
    }

    @Test
    fun processCandidatesRequirePresentEbookAndAudiobook() {
        val books = json.decodeFromString<List<StorytellerBookDto>>(
            """
            [
              {"uuid":"both","title":"Both","ebook":{"uuid":"e1"},"audiobook":{"uuid":"a1"}},
              {"uuid":"ebook-only","title":"Ebook","ebook":{"uuid":"e2"}},
              {"uuid":"audio-missing","title":"Missing","ebook":{"uuid":"e3"},"audiobook":{"uuid":"a3","missing":1}},
              {"uuid":"","title":"No id","ebook":{"uuid":"e4"},"audiobook":{"uuid":"a4"}}
            ]
            """.trimIndent(),
        )

        val candidates = storytellerProcessCandidates(books)

        assertEquals(listOf("both"), candidates.map { it.uuid })
    }

    @Test
    fun processingActiveTracksCurrentServerStatuses() {
        val queued = json.decodeFromString<StorytellerBookDto>(
            """{"uuid":"b","title":"t","readaloud":{"uuid":"r","status":"QUEUED","queuePosition":3}}""",
        )
        val processing = json.decodeFromString<StorytellerBookDto>(
            """{"uuid":"b","title":"t","readaloud":{"uuid":"r","status":"PROCESSING","currentStage":"TRANSCRIBING","stageProgress":0.4}}""",
        )
        val aligned = json.decodeFromString<StorytellerBookDto>(
            """{"uuid":"b","title":"t","readaloud":{"uuid":"r","status":"ALIGNED","filepath":"x.epub"}}""",
        )
        val staleQueuePosition = json.decodeFromString<StorytellerBookDto>(
            """{"uuid":"b","title":"t","readaloud":{"uuid":"r","status":"STOPPED","queuePosition":3}}""",
        )

        assertTrue(storytellerProcessingActive(queued.readaloud))
        assertTrue(storytellerProcessingActive(processing.readaloud))
        assertFalse(storytellerProcessingActive(aligned.readaloud))
        assertFalse(storytellerProcessingActive(staleQueuePosition.readaloud))
        assertFalse(storytellerProcessingActive(null))
    }

    @Test
    fun shelfBodyOmitsBlankOptionalFields() {
        val body = storytellerShelfBody(name = "Read Next", description = " ", icon = null, color = "#112233")

        assertEquals(setOf("name", "color"), body.keys)
        assertEquals("\"Read Next\"", body["name"].toString())
    }

    @Test
    fun shelfBooksBodyPreservesManualOrder() {
        val body = storytellerShelfBooksBody(listOf("book-3", "book-1", "book-2"))

        assertEquals(
            listOf("book-3", "book-1", "book-2"),
            body.getValue("books").jsonArray.map { it.jsonPrimitive.content },
        )
    }
}
