package com.enve.silo

import com.enve.silo.dto.SiloItemListResponse
import com.enve.silo.dto.SiloScoredItemsResponse
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SiloServerToolsDtoTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun decodesHistoryPage() {
        val page = json.decodeFromString<SiloItemListResponse>(
            """
            {"items":[
              {"content_id":"c1","type":"ebook","title":"Piranesi","genres":[],"keywords":[],"status":"available","runtime":0},
              {"content_id":"c2","type":"audiobook","title":"Chapter 4","series_title":"The Expanse","genres":[],"keywords":[],"status":"available","runtime":3600}
            ],"has_more":true}
            """.trimIndent(),
        )

        assertEquals(2, page.items.size)
        assertTrue(page.hasMore)
        assertEquals("The Expanse", page.items[1].seriesTitle)
        assertEquals(3600, page.items[1].runtime)
        assertEquals(null, page.items[0].seriesTitle)
    }

    @Test
    fun decodesScoredItems() {
        val response = json.decodeFromString<SiloScoredItemsResponse>(
            """{"items":[{"media_item_id":"c9","score":0.82,"reason":"embedding"},{"media_item_id":"c4","score":0.4,"reason":"cowatch","reason_detail":"seen together"}]}""",
        )

        assertEquals("c9", response.items.first().mediaItemId)
        assertEquals(0.82, response.items.first().score, 0.0001)
        assertEquals("seen together", response.items[1].reasonDetail)
    }

    @Test
    fun decodesEmptyRecommendationPayload() {
        val response = json.decodeFromString<SiloScoredItemsResponse>("""{"items":[]}""")

        assertTrue(response.items.isEmpty())
    }
}
