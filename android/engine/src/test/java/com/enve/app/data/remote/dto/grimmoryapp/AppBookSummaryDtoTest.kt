package com.enve.app.data.remote.dto.grimmoryapp

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class AppBookSummaryDtoTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `decodes numeric book ids returned by shelf endpoints`() {
        val page = json.decodeFromString(
            AppPageDto.serializer(AppBookSummaryDto.serializer()),
            """
            {
              "content": [
                {
                  "id": 75,
                  "title": "Spellmonger",
                  "libraryId": 1,
                  "primaryFileType": "M4B"
                }
              ],
              "page": 0,
              "size": 60,
              "totalElements": 1,
              "totalPages": 1,
              "hasNext": false
            }
            """.trimIndent(),
        )

        assertEquals("75", page.content.single().id)
    }

    @Test
    fun `continues to decode string book ids`() {
        val book = json.decodeFromString(
            AppBookSummaryDto.serializer(),
            """{"id":"75","title":"Spellmonger"}""",
        )

        assertEquals("75", book.id)
    }
}
