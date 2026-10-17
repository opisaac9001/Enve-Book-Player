package com.enve.app.data.remote.dto

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GrimmoryComicMetadataTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun readsDirectionFromTheStandardBookEndpointWithoutDecodingUnrelatedMetadata() {
        for (direction in listOf("rtl", "ltr")) {
            val detail = json.decodeFromString<GrimmoryBookProgressDetailDto>(
                """{"id":12,"metadata":{"authors":[{"id":1,"name":"Author"}],"comicMetadata":{"readingDirection":"$direction"}}}""",
            )
            assertEquals(direction, detail.metadata?.comicMetadata?.readingDirection)
        }
    }

    @Test
    fun absentDirectionRemainsUnknown() {
        for (body in listOf("{}", """{"metadata":{}}""", """{"metadata":{"comicMetadata":{}}}""")) {
            assertNull(json.decodeFromString<GrimmoryBookProgressDetailDto>(body).metadata?.comicMetadata?.readingDirection)
        }
    }
}
